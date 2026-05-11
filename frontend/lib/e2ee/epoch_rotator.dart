import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/secure_store/key_handle_adapter.dart';

import 'album_keys.dart';
import 'epoch_api.dart';
import 'identity.dart';
import 'prekey_api.dart';
import 'x3dh_session.dart';

// EpochRotator : the initiator side of an epoch transition (§4.1 + §4.2 + §5
// bootstrap). The bootstrap case (epoch 0 on album create) is the lone member
// = creator scenario : member add (§6) and member remove (§7) reuse the same
// machinery with multi recipient member lists

// Foundation now : the rotate() method takes any list of recipients, so §6 /
// §7 will pass non self lists when those phases land. Self wrap on epoch 0 is
// ceremonial today (no device recovery flow yet : new device = new IK = old
// wraps dont decrypt anyway) but it keeps the wire format consistent for when
// recovery does land

class RotateRecipient {
  // memberToken : 32B raw token (the same bytes that appear in album_members
  // member_token on the server). userId : canonical UUID string used to fetch
  // the recipient's prekey bundle via GET /users/{id}/prekey-bundle
  final Uint8List memberToken;
  final String userId;
  const RotateRecipient({required this.memberToken, required this.userId});
}

class EpochRotator {
  final EpochApi _epochs;
  final PrekeyApi _prekeys;
  final IdentityService _identity;
  final AlbumKeyStore _aks;
  final Now _now;

  EpochRotator({
    required EpochApi epochs,
    required PrekeyApi prekeys,
    required IdentityService identity,
    required AlbumKeyStore aks,
    Now? now,
  })  : _epochs = epochs,
        _prekeys = prekeys,
        _identity = identity,
        _aks = aks,
        _now = now ?? DateTime.now;

  // Bootstrap : first epoch (=0) for a brand new album with the creator as
  // the only member. Generates MK_0, self wraps it via X3DH against the
  // creator's own prekey bundle, posts /albums/{id}/epoch, and installs
  // MK_0 locally so the upload pipeline can immediately use it
  Future<void> bootstrap({
    required Uint8List albumIdBytes,
    required Uint8List creatorMemberToken,
    required String creatorUserId,
  }) async {
    await rotate(
      albumIdBytes: albumIdBytes,
      epoch: 0,
      recipients: [
        RotateRecipient(memberToken: creatorMemberToken, userId: creatorUserId),
      ],
    );
  }

  // Rotate : the general path. Wraps the new MK for each recipient. epoch is
  // the new epoch number (next_epoch = current_epoch + 1, or 0 for bootstrap)
  // recipients must be the FULL active member set : the server recomputes
  // member_set_hash live in the txn and rejects on drift
  Future<void> rotate({
    required Uint8List albumIdBytes,
    required int epoch,
    required List<RotateRecipient> recipients,
  }) async {
    if (albumIdBytes.length != 16) {
      throw ArgumentError(
          'albumIdBytes must be 16 bytes, got ${albumIdBytes.length}');
    }
    if (recipients.isEmpty) {
      throw ArgumentError('recipients must be non empty');
    }
    if (epoch < 0) {
      throw ArgumentError('epoch must be >= 0, got $epoch');
    }

    // mint a fresh MK
    final mk = Csprng.bytes(32);
    try {
      // per recipient, fetch + verify prekey bundle, run X3DH
      // initiate, wrap MK under shared_secret, sign the wrap. SK is zeroed
      // immediately after the wrap encrypt
      final wraps = <SetEpochWrap>[];
      for (final r in recipients) {
        final bundle = await _prekeys.fetchPrekeyBundle(r.userId);
        await bundle.verify(now: _now);
        final init = await X3dhSession.initiate(
          bundle: bundle,
          albumId: albumIdBytes,
          identity: _identity,
        );
        final wrap = await _wrapMK(
          sk: init.sharedSecret,
          mk: mk,
          albumIdBytes: albumIdBytes,
          epoch: epoch,
        );
        init.sharedSecret.fillRange(0, init.sharedSecret.length, 0);

        final senderSig = await _signSenderMsg(
          albumIdBytes: albumIdBytes,
          epoch: epoch,
          wrap: wrap,
        );
        wraps.add(SetEpochWrap(
          recipientToken: r.memberToken,
          ekPub: init.ekPub,
          opkIdxUsed: init.opkIdx,
          wrap: wrap,
          senderSig: senderSig,
        ));
      }

      // build the §4.1 byte hashes : mirror server side byte for byte
      final tokens = recipients.map((r) => r.memberToken).toList();
      final memberSetHash = await _memberSetHash(tokens);
      final wrapsHash = await _wrapsHash(wraps);
      final envelopeSig = await _signEnvelopeMsg(
        albumIdBytes: albumIdBytes,
        epoch: epoch,
        memberSetHash: memberSetHash,
        wrapsHash: wrapsHash,
      );

      // POST /albums/{id}/epoch. Server validates everything atomically
      await _epochs.setEpoch(
        _uuidStringFromBytes(albumIdBytes),
        SetEpochRequest(
          epoch: epoch,
          memberSetHash: memberSetHash,
          wraps: wraps,
          envelopeSig: envelopeSig,
        ),
      );

      //install MK locally. installVerified is idempotent on byte
      // equal re install so if a fanout race already installed it (via §4.2
      // responder path) we no op cleanly
      await _aks.installVerified(
        albumId: albumIdBytes,
        epoch: epoch,
        mk: mk,
        backfill: false,
      );
    } finally {
      mk.fillRange(0, mk.length, 0);
    }
  }

  // _wrapMK : AES-GCM(SK, fresh_nonce, MK, aad = album_id ‖ u32_be(epoch))
  // Output is the full 61 byte wire (VER ‖ NONCE ‖ TAG ‖ CT) : server splits
  // off VER+NONCE and stores NONCE + TAG_CT separately
  Future<Uint8List> _wrapMK({
    required Uint8List sk,
    required Uint8List mk,
    required Uint8List albumIdBytes,
    required int epoch,
  }) {
    final aad = Uint8List(16 + 4);
    aad.setRange(0, 16, albumIdBytes);
    ByteData.sublistView(aad, 16).setUint32(0, epoch, Endian.big);
    return Aead.encrypt(
      version: kVerAesGcm,
      key: sk,
      plaintext: mk,
      aad: aad,
    );
  }

  // _signSenderMsg : Ed25519_sign(IK_priv, SHA256(album_id ‖ u32_be(epoch) ‖
  // wrap_blob)) per §4.2 D3. Same hash the §4.2 responder recomputes before
  // accepting the wrap. Uses identity.useIk so the seed never escapes
  Future<Uint8List> _signSenderMsg({
    required Uint8List albumIdBytes,
    required int epoch,
    required Uint8List wrap,
  }) async {
    final buf = Uint8List(16 + 4 + wrap.length);
    buf.setRange(0, 16, albumIdBytes);
    ByteData.sublistView(buf, 16, 20).setUint32(0, epoch, Endian.big);
    buf.setRange(20, buf.length, wrap);
    final h = await cg.Sha256().hash(buf);
    final msg = Uint8List.fromList(h.bytes);
    return _identity.useIk<Uint8List>((seed) async {
      final kp = await KeyHandleAdapter.toEd25519(seed);
      return Sign.sign(kp, msg);
    });
  }

  // _signEnvelopeMsg : Ed25519_sign(IK_priv, "epoch-set-v1" ‖ album_id ‖
  // u32_be(epoch) ‖ member_set_hash ‖ wraps_hash) per §4.1. Server verifies
  // this against the caller's IK_pub before committing the transaction
  Future<Uint8List> _signEnvelopeMsg({
    required Uint8List albumIdBytes,
    required int epoch,
    required Uint8List memberSetHash,
    required Uint8List wrapsHash,
  }) async {
    final salt = _kSaltEpochSet;
    final buf = Uint8List(salt.length + 16 + 4 + 32 + 32);
    var i = 0;
    buf.setRange(i, i + salt.length, salt);
    i += salt.length;
    buf.setRange(i, i + 16, albumIdBytes);
    i += 16;
    ByteData.sublistView(buf, i, i + 4).setUint32(0, epoch, Endian.big);
    i += 4;
    buf.setRange(i, i + 32, memberSetHash);
    i += 32;
    buf.setRange(i, i + 32, wrapsHash);
    return _identity.useIk<Uint8List>((seed) async {
      final kp = await KeyHandleAdapter.toEd25519(seed);
      return Sign.sign(kp, buf);
    });
  }
}

// _kSaltEpochSet : mirrors internal/crypto/salts.go SaltEpochSet byte for byte
final Uint8List _kSaltEpochSet = Uint8List.fromList('epoch-set-v1'.codeUnits);

// _memberSetHash : SHA256( u32_be(N) ‖ sorted tokens ). Mirrors
// internal/e2ee/epoch/service.go MemberSetHash exactly
Future<Uint8List> _memberSetHash(List<Uint8List> tokens) async {
  final sorted = [...tokens]..sort(_byteCompare);
  final builder = BytesBuilder(copy: false);
  final lenBuf = Uint8List(4);
  ByteData.sublistView(lenBuf).setUint32(0, sorted.length, Endian.big);
  builder.add(lenBuf);
  for (final t in sorted) {
    builder.add(t);
  }
  final h = await cg.Sha256().hash(builder.toBytes());
  return Uint8List.fromList(h.bytes);
}

// _wrapsHash : SHA256( u32_be(N) ‖ for each wrap sorted by recipient_token :
// token(32) ‖ ek_pub(32) ‖ u32_be(opk_idx; 0xFFFFFFFF if null) ‖
// u32_be(len(wrap)) ‖ wrap ‖ u32_be(len(sender_sig)) ‖ sender_sig )
// Mirrors internal/e2ee/epoch/service.go WrapsHash exactly
Future<Uint8List> _wrapsHash(List<SetEpochWrap> wraps) async {
  final sorted = [...wraps]
    ..sort((a, b) => _byteCompare(a.recipientToken, b.recipientToken));
  final builder = BytesBuilder(copy: false);
  final u32 = Uint8List(4);
  ByteData.sublistView(u32).setUint32(0, sorted.length, Endian.big);
  builder.add(Uint8List.fromList(u32));
  for (final w in sorted) {
    builder.add(w.recipientToken);
    builder.add(w.ekPub);
    final idx = w.opkIdxUsed ?? 0xFFFFFFFF;
    ByteData.sublistView(u32).setUint32(0, idx, Endian.big);
    builder.add(Uint8List.fromList(u32));
    ByteData.sublistView(u32).setUint32(0, w.wrap.length, Endian.big);
    builder.add(Uint8List.fromList(u32));
    builder.add(w.wrap);
    ByteData.sublistView(u32).setUint32(0, w.senderSig.length, Endian.big);
    builder.add(Uint8List.fromList(u32));
    builder.add(w.senderSig);
  }
  final h = await cg.Sha256().hash(builder.toBytes());
  return Uint8List.fromList(h.bytes);
}

int _byteCompare(Uint8List a, Uint8List b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final d = a[i] - b[i];
    if (d != 0) return d;
  }
  return a.length - b.length;
}

String _uuidStringFromBytes(Uint8List b) {
  final s = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
      '-${s.substring(16, 20)}-${s.substring(20)}';
}
