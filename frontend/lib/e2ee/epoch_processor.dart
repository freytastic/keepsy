import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/secure_store/key_handle_adapter.dart';
import 'package:keepsy/secure_store/key_store_exceptions.dart';

import 'album_keys.dart';
import 'epoch_api.dart';
import 'identity.dart';
import 'invite_api.dart';
import 'join.dart';
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
  // §6.3 join_complete receipt. Null when the processor is wired without invite
  // support (older callers / tests that don't exercise the join path)
  final InviteApi? _invites;

  // hex(albumId) -> tail of the in flight chain : new events queue behind it
  final Map<String, Future<void>> _chains = {};

  // Fires after a successful _backfillJoin + postJoinComplete : main.dart
  // listens to refresh AppState.albums for the freshly joined album. We
  // emit AFTER the receipt POST succeeds so a listener can trust the keys
  // are durably installed
  final StreamController<Uint8List> _joined =
      StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get joinedAlbums => _joined.stream;

  EpochProcessor({
    required EpochApi api,
    required IdentityService identity,
    required AlbumKeyStore store,
    required MemberDirectory directory,
    InviteApi? invites,
    BackoffSchedule? backoff,
    int maxRetries = 3,
  })  : _api = api,
        _identity = identity,
        _store = store,
        _directory = directory,
        _invites = invites,
        _backoff = backoff ?? _defaultBackoff,
        _maxRetries = maxRetries;

  // Mutexed per albumId. Serial within an album, parallel across albums
  // joined==true (§6.1 epoch_changed{joined:true} or cold start with zero local
  // MKs) backfills every epoch 0..epoch and posts the join_complete receipt
  Future<void> handleEvent({
    required Uint8List albumId,
    required int epoch,
    bool joined = false,
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
      if (joined) {
        await _backfillJoin(albumId, epoch);
      } else {
        await _doHandle(albumId, epoch);
      }
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
        if (latest < 0) {
          // Zero local MKs but the album has epochs : this client just joined and
          // missed the live event (EmitToUsers is live-only) treat as a join
          await handleEvent(albumId: id, epoch: cur.currentEpoch, joined: true);
        } else {
          for (var n = latest + 1; n <= cur.currentEpoch; n++) {
            await handleEvent(albumId: id, epoch: n);
          }
        }
      } catch (_) {}
    }
  }

  Future<void> _doHandle(Uint8List albumId, int epoch) async {
    await _installEpoch(albumId, epoch, backfill: false);
  }

  // _backfillJoin installs every epoch 0..current (out-of-order safe via
  // backfill:true) then posts a single join_complete receipt for 'current'
  // ek_pub_admin is the shared X3DH ephemeral carried on the delivered wraps
  Future<void> _backfillJoin(Uint8List albumId, int current) async {
    final albumStr = _uuidString(albumId);
    Uint8List? ekPubAdmin;
    for (var e = 0; e <= current; e++) {
      final ek = await _installEpoch(albumId, e, backfill: true);
      ekPubAdmin ??= ek;
    }
    if (ekPubAdmin == null) return;
    if (_invites == null) return;
    final msg = joinCompleteMsg(albumId, current, ekPubAdmin);
    final sig = await _identity.useIk<Uint8List>((seed) async {
      final kp = await KeyHandleAdapter.toEd25519(seed);
      return Sign.sign(kp, msg);
    });
    await _invites.postJoinComplete(
      albumId: albumStr,
      epoch: current,
      ekPubAdmin: ekPubAdmin,
      sig: sig,
    );
    _joined.add(albumId);
  }

  // Close the joinedAlbums stream. Tests + the eventual app shutdown path
  // call this : the runtime app holds the processor for its lifetime so
  // normal use never invokes it
  void dispose() {
    _joined.close();
  }

  // Fetch + verify + derive + decrypt + install one epoch's wrap. Returns the
  // wrap's ek_pub (the X3DH ephemeral) so the join path can build the receipt
  Future<Uint8List> _installEpoch(Uint8List albumId, int epoch,
      {required bool backfill}) async {
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

    // Try current -> pending -> previous -> archived. Pending covers an
    // ambiguous rotation; previous and archived cover delayed wraps
    final aad = _aad(albumId, epoch);
    var vanished = false;
    Future<Uint8List?> attempt(SpkSlot slot) async {
      final r =
          await _unwrapWithSpk(albumId, epoch, envelope, pubs, aad, slot: slot);
      vanished = vanished || r.vanished;
      return r.mk;
    }

    Uint8List? mk = await attempt(SpkSlot.current);
    if (mk == null && _identity.hasPendingSpk) {
      mk = await attempt(SpkSlot.pending);
    }
    if (mk == null && _identity.hasPreviousSpk) {
      mk = await attempt(SpkSlot.previous);
    }
    // Archive fallback is bounded to one retained key
    if (mk == null && _identity.hasArchivedSpk) {
      mk = await attempt(SpkSlot.archived);
    }
    // Reconciliation may have promoted a vanished slot after current was tried
    if (mk == null && vanished) {
      mk = await attempt(SpkSlot.current);
    }
    if (mk == null) {
      throw const WrapVerificationException('aead_auth_failed');
    }
    try {
      await _store.installVerified(
        albumId: albumId,
        epoch: epoch,
        mk: mk,
        backfill: backfill,
      );
    } finally {
      mk.fillRange(0, mk.length, 0);
    }
    return envelope.ekPub;
  }

  // Returns a null MK on authentication failure and marks slots that disappear
  // during concurrent reconciliation. The derived secret is always zeroed
  Future<({Uint8List? mk, bool vanished})> _unwrapWithSpk(
    Uint8List albumId,
    int epoch,
    WrapEnvelope envelope,
    MemberPubs pubs,
    Uint8List aad, {
    required SpkSlot slot,
  }) async {
    Uint8List? sk;
    try {
      // A non current slot may disappear after its presence check
      sk = await X3dhSession.derive(
        identity: _identity,
        ekPub: envelope.ekPub,
        peerLkPub: pubs.lkPub,
        opkIdx: envelope.opkIdxUsed,
        albumId: albumId,
        spkSlot: slot,
      );
      try {
        return (
          mk: await Aead.decrypt(wire: envelope.wrap, key: sk, aad: aad),
          vanished: false
        );
      } on AeadAuthFailed {
        return (mk: null, vanished: false);
      }
    } on StateError {
      // Reconciliation cleared the label
      if (slot == SpkSlot.current) rethrow;
      return (mk: null, vanished: true);
    } on KeyNotFoundException {
      // Reconciliation deleted the replaced handle
      if (slot == SpkSlot.current) rethrow;
      return (mk: null, vanished: true);
    } finally {
      if (sk != null) sk.fillRange(0, sk.length, 0);
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
