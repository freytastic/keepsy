import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:keepsy/crypto/primitives.dart';

import 'album_keys.dart';
import 'epoch_api.dart';
import 'identity.dart';
import 'member_directory.dart';
import 'wrap_envelope.dart';
import 'x3dh_session.dart';

// Spec §5.4 : OpkNotFoundException is part of the EpochProcessor surface so
// callers don't need to also import x3dh_session.dart to handle it
export 'x3dh_session.dart' show OpkNotFoundException;

// Drives MK delivery on incoming e2ee.epoch_changed events and on cold start /
// reconnect catch up. Per album mutex serialises events so install order can
// never blip backwards under WS flap : cross album work runs in parallel

typedef BackoffSchedule = Duration Function(int attempt);

const Duration _kRetry0 = Duration(milliseconds: 200);
const Duration _kRetry1 = Duration(milliseconds: 800);
const Duration _kRetry2 = Duration(milliseconds: 3200);

Duration _defaultBackoff(int attempt) {
  if (attempt == 0) return _kRetry0;
  if (attempt == 1) return _kRetry1;
  return _kRetry2;
}

class EpochProcessor {
  final EpochApi _api;
  final IdentityService _identity;
  final AlbumKeyStore _store;
  final MemberDirectory _directory;
  final BackoffSchedule _backoff;
  final int _maxRetries;

  // hex(albumId) -> tail of the in flight chain : new events queue behind it
  final Map<String, Future<void>> _chains = {};

  EpochProcessor({
    required EpochApi api,
    required IdentityService identity,
    required AlbumKeyStore store,
    required MemberDirectory directory,
    BackoffSchedule? backoff,
    int maxRetries = 3,
  })  : _api = api,
        _identity = identity,
        _store = store,
        _directory = directory,
        _backoff = backoff ?? _defaultBackoff,
        _maxRetries = maxRetries;

  // Mutexed per albumId. Serial within an album, parallel across albums
  Future<void> handleEvent({
    required Uint8List albumId,
    required int epoch,
  }) async {
    final hex = _hexAlbum(albumId);
    final prev = _chains[hex];
    Future<void> chained() async {
      if (prev != null) {
        try {
          await prev;
        } catch (_) {
          // Prior failure must not poison the chain : the next event still runs
        }
      }
      await _doHandle(albumId, epoch);
    }

    final mine = chained();
    _chains[hex] = mine;
    try {
      await mine;
    } finally {
      if (identical(_chains[hex], mine)) _chains.remove(hex);
    }
  }

  // Cold start + WS reconnect catch up. Sequential within an album (a failed
  // epoch leaves later ones unreachable since latestEpoch wouldnt advance and
  // the next would later look like a downgrade), but resilient across albums :
  // a poison wrap on album A must not block catch up on B
  Future<void> catchUpAll(List<Uint8List> albumIds) async {
    for (final id in albumIds) {
      try {
        final cur = await _api.getCurrentEpoch(_uuidString(id));
        if (cur == null) continue;
        final latest = await _store.latestEpoch(id);
        for (var n = latest + 1; n <= cur.currentEpoch; n++) {
          await handleEvent(albumId: id, epoch: n);
        }
      } catch (e, s) {
        developer.log('catchUpAll failed for album',
            name: 'keepsy.e2ee', error: e, stackTrace: s);
      }
    }
  }

  Future<void> _doHandle(Uint8List albumId, int epoch) async {
    final albumIdStr = _uuidString(albumId);
    final envelope = await _fetchWithRetry(albumIdStr, epoch);
    envelope.verifyShape();

    final pubs = await _directory.lookup(albumId, envelope.senderToken);
    if (pubs == null) {
      // sender_token doesnt resolve to a member : cant verify, must bail
      throw const WrapVerificationException('sig_invalid');
    }

    final msg = await _msgToSign(albumId, epoch, envelope.wrap);
    final ok = await Sign.verify(pubs.ikPub, msg, envelope.senderSig);
    if (!ok) throw const WrapVerificationException('sig_invalid');

    Uint8List? sk;
    Uint8List? mk;
    try {
      sk = await X3dhSession.derive(
        identity: _identity,
        ekPub: envelope.ekPub,
        peerLkPub: pubs.lkPub,
        opkIdx: envelope.opkIdxUsed,
        albumId: albumId,
      );
      final aad = _aad(albumId, epoch);
      try {
        mk = await Aead.decrypt(
          wire: envelope.wrap,
          key: sk,
          aad: aad,
        );
      } on AeadAuthFailed {
        throw const WrapVerificationException('aead_auth_failed');
      }
      await _store.installVerified(
        albumId: albumId,
        epoch: epoch,
        mk: mk,
        backfill: false,
      );
    } finally {
      if (sk != null) sk.fillRange(0, sk.length, 0);
      if (mk != null) mk.fillRange(0, mk.length, 0);
    }
  }

  Future<WrapEnvelope> _fetchWithRetry(String albumId, int epoch) async {
    for (var i = 0;; i++) {
      try {
        return await _api.getWrap(albumId, epoch);
      } on EpochWrapNotFoundException {
        if (i >= _maxRetries - 1) rethrow;
        await Future.delayed(_backoff(i));
      }
    }
  }
}

// AAD = album_id(16) ‖ uint32_be(epoch) per §4.1
Uint8List _aad(Uint8List albumId, int epoch) {
  final out = Uint8List(16 + 4);
  out.setRange(0, 16, albumId);
  ByteData.sublistView(out, 16, 20).setUint32(0, epoch, Endian.big);
  return out;
}

// SHA256(album_id(16) ‖ u32_be(epoch) ‖ wrap_blob_bytes) per §4.2 / D3
Future<Uint8List> _msgToSign(
    Uint8List albumId, int epoch, Uint8List wrap) async {
  final buf = Uint8List(16 + 4 + wrap.length);
  buf.setRange(0, 16, albumId);
  ByteData.sublistView(buf, 16, 20).setUint32(0, epoch, Endian.big);
  buf.setRange(20, buf.length, wrap);
  final h = await cg.Sha256().hash(buf);
  return Uint8List.fromList(h.bytes);
}

String _hexAlbum(Uint8List albumId) =>
    albumId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

// Canonical 8-4-4-4-12 hex form. Avoid pulling package:uuid here so lib/e2ee/
// stays free of optional dependencies
String _uuidString(Uint8List albumId) {
  if (albumId.length != 16) {
    throw ArgumentError('albumId must be 16 bytes, got ${albumId.length}');
  }
  final s = _hexAlbum(albumId);
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
      '-${s.substring(16, 20)}-${s.substring(20)}';
}
