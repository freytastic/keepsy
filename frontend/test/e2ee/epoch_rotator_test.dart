import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/epoch_api.dart';
import 'package:keepsy/e2ee/epoch_rotator.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/e2ee/prekey_api.dart';
import 'package:keepsy/e2ee/prekey_bundle.dart';
import 'package:keepsy/e2ee/wrap_envelope.dart';
import 'package:keepsy/e2ee/x3dh_session.dart';

import '_admin_test_helpers.dart';

Uint8List _albumId([int seed = 0xA1]) =>
    Uint8List.fromList(List<int>.filled(16, seed));

// _CaptureEpochApi : records every setEpoch call so the test can inspect what
// the rotator built. getCurrentEpoch + getWrap are unused by the rotator path
class _CaptureEpochApi implements EpochApi {
  String? lastAlbumId;
  SetEpochRequest? lastRequest;
  int calls = 0;

  @override
  Future<EpochCurrent?> getCurrentEpoch(String _) async => null;

  @override
  Future<WrapEnvelope> getWrap(String _, int __) async =>
      throw UnimplementedError();

  @override
  Future<void> setEpoch(String albumId, SetEpochRequest req) async {
    calls++;
    lastAlbumId = albumId;
    lastRequest = req;
  }
}

// _StubPrekeyApi : fetchPrekeyBundle returns the pre populated bundle. Other
// methods unused by the rotator path ; left as throwing stubs for clarity
class _StubPrekeyApi implements PrekeyApi {
  final PrekeyBundle Function(String userId) bundleFor;
  _StubPrekeyApi(this.bundleFor);

  @override
  Future<int> opkCount() async => 20;
  @override
  Future<void> replenishOpks(
          {required List<PrekeyOpk> opks,
          required Uint8List replenishSig}) async =>
      throw UnimplementedError();
  @override
  Future<void> rotateSpk(
          {required Uint8List spkPub,
          required Uint8List spkSig,
          required int spkTs,
          required Uint8List rotationSig}) async =>
      throw UnimplementedError();
  @override
  Future<void> upsertIdentity(
          {required Uint8List ikPub,
          required Uint8List lkPub,
          required Uint8List spkPub,
          required Uint8List spkSig,
          required int spkTs}) async =>
      throw UnimplementedError();
  @override
  Future<PrekeyBundle> fetchPrekeyBundle(String userId) async =>
      bundleFor(userId);
}

// Anchored : _spkTs and _now are within the ±90 day window the bundle verifier
// enforces (PrekeyBundle.verify). The initiator (rotator) verifies the bundle
// before X3DH initiate, unlike the responder side tests which skip verify
final DateTime _now = DateTime.utc(2026, 5, 11, 12);
final int _spkTs = _now.millisecondsSinceEpoch ~/ 1000 - 3600; // 1h ago

// _opkPubFrom : reads OPK_pub[idx] off the identity so the stub bundle can
// expose a real OPK that derive() will later find in the same SecureKeyStore
Future<Uint8List> _opkPubFrom(IdentityService svc, int idx) async {
  final pub = await svc.tryUseOpk<Uint8List>(idx, (priv) async {
    final kp = await cg.X25519().newKeyPairFromSeed(priv);
    return Uint8List.fromList((await kp.extractPublicKey()).bytes);
  });
  if (pub == null) {
    throw StateError('no OPK at idx=$idx in identity');
  }
  return pub;
}

Future<Uint8List> _ikPubOf(IdentityService svc) {
  return svc.useIk<Uint8List>((seed) async {
    final kp = await cg.Ed25519().newKeyPairFromSeed(seed);
    return Uint8List.fromList((await kp.extractPublicKey()).bytes);
  });
}

Future<Uint8List> _lkPubOf(IdentityService svc) {
  return svc.useLk<Uint8List>((priv) async {
    final kp = await cg.X25519().newKeyPairFromSeed(priv);
    return Uint8List.fromList((await kp.extractPublicKey()).bytes);
  });
}

// _newCreatorStack : bootstraps a fresh IdentityService + the AlbumKeyStore
// the rotator will install MK into. Returns the pieces tests need to poke
Future<
    ({
      IdentityService svc,
      AlbumKeyStore aks,
      Uint8List senderToken,
      Uint8List ikPub,
      Uint8List lkPub
    })> _newCreatorStack() async {
  final (svc: svc, store: store) = await newResponderIdentity();
  final aks = AlbumKeyStore(store);
  await aks.initialize();
  return (
    svc: svc,
    aks: aks,
    senderToken: Csprng.bytes(32),
    ikPub: await _ikPubOf(svc),
    lkPub: await _lkPubOf(svc),
  );
}

void main() {
  group('EpochRotator.bootstrap', () {
    test(
        'installs MK_0 locally and POSTs set_epoch with the creator as sole member',
        () async {
      final c = await _newCreatorStack();
      final opkPub = await _opkPubFrom(c.svc, 0);
      final bundle = await buildResponderBundle(
        responder: c.svc,
        spkTs: _spkTs,
        opk: (idx: 0, keyPub: opkPub),
      );

      final caps = _CaptureEpochApi();
      final rotator = EpochRotator(
        epochs: caps,
        prekeys: _StubPrekeyApi((_) => bundle),
        identity: c.svc,
        aks: c.aks,
        now: () => _now,
      );

      await rotator.bootstrap(
        albumIdBytes: _albumId(),
        creatorMemberToken: c.senderToken,
        creatorUserId: 'creator-user-id',
      );

      // MK_0 installed locally
      expect(await c.aks.latestEpoch(_albumId()), 0);
      expect(await c.aks.presentEpochs(_albumId()), [0]);

      // setEpoch called once with creator as sole recipient
      expect(caps.calls, 1);
      final req = caps.lastRequest!;
      expect(req.epoch, 0);
      expect(req.wraps.length, 1);
      expect(req.wraps[0].recipientToken, equals(c.senderToken));
      expect(req.wraps[0].wrap.length, 61); // VER + NONCE + TAG + CT(32B MK)
      expect(req.wraps[0].wrap[0], kVerAesGcm);
      expect(req.wraps[0].senderSig.length, 64);
      expect(req.envelopeSig.length, 64);
      expect(req.memberSetHash.length, 32);
    });

    test('self wrap is decryptable via the §4.2 responder path', () async {
      // Strongest round trip : take the wrap the rotator produced and run it
      // through X3dhSession.derive + Aead.decrypt to recover MK. Compare
      // against the MK AlbumKeyStore holds. Both must match byte for byte if
      // the wrap is built right
      final c = await _newCreatorStack();
      final opkPub = await _opkPubFrom(c.svc, 0);
      final bundle = await buildResponderBundle(
        responder: c.svc,
        spkTs: _spkTs,
        opk: (idx: 0, keyPub: opkPub),
      );
      final caps = _CaptureEpochApi();
      final rotator = EpochRotator(
        epochs: caps,
        prekeys: _StubPrekeyApi((_) => bundle),
        identity: c.svc,
        aks: c.aks,
        now: () => _now,
      );

      await rotator.bootstrap(
        albumIdBytes: _albumId(),
        creatorMemberToken: c.senderToken,
        creatorUserId: 'self',
      );

      final w = caps.lastRequest!.wraps.single;
      final sk = await X3dhSession.derive(
        identity: c.svc,
        ekPub: w.ekPub,
        peerLkPub: c.lkPub,
        opkIdx: w.opkIdxUsed,
        albumId: _albumId(),
      );
      final aad = Uint8List(20);
      aad.setRange(0, 16, _albumId());
      final mk = await Aead.decrypt(wire: w.wrap, key: sk, aad: aad);

      final installed = await c.aks
          .useMk<List<int>>(_albumId(), 0, (b) async => List<int>.from(b));
      expect(mk, equals(installed));
    });

    test('envelope_sig verifies against creator IK_pub for the §4.1 byte msg',
        () async {
      final c = await _newCreatorStack();
      final opkPub = await _opkPubFrom(c.svc, 0);
      final bundle = await buildResponderBundle(
        responder: c.svc,
        spkTs: _spkTs,
        opk: (idx: 0, keyPub: opkPub),
      );
      final caps = _CaptureEpochApi();
      final rotator = EpochRotator(
        epochs: caps,
        prekeys: _StubPrekeyApi((_) => bundle),
        identity: c.svc,
        aks: c.aks,
        now: () => _now,
      );
      await rotator.bootstrap(
        albumIdBytes: _albumId(),
        creatorMemberToken: c.senderToken,
        creatorUserId: 'self',
      );

      final req = caps.lastRequest!;
      // Rebuild the §4.1 envelope message : "epoch-set-v1" ‖ album_id(16) ‖
      // u32_be(epoch) ‖ member_set_hash(32) ‖ wraps_hash(32). Recompute
      // wraps_hash independently so this test catches any drift between
      // rotator and the byte format spec
      final salt = Uint8List.fromList('epoch-set-v1'.codeUnits);
      final wrapsHash = await _recomputeWrapsHash(req.wraps);
      final msg = BytesBuilder(copy: false)
        ..add(salt)
        ..add(_albumId());
      final u32 = Uint8List(4);
      ByteData.sublistView(u32).setUint32(0, 0, Endian.big);
      msg.add(Uint8List.fromList(u32));
      msg.add(req.memberSetHash);
      msg.add(wrapsHash);

      final pk = cg.SimplePublicKey(c.ikPub, type: cg.KeyPairType.ed25519);
      expect(await Sign.verify(pk, msg.toBytes(), req.envelopeSig), isTrue);
    });
  });
}

// _recomputeWrapsHash : duplicate of the rotator's private _wrapsHash byte
// layout. If the rotator drifts from the §4.1 format this test catches it
Future<Uint8List> _recomputeWrapsHash(List<SetEpochWrap> wraps) async {
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
