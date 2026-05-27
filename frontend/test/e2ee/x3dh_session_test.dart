import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/e2ee/identity_label_map.dart';
import 'package:keepsy/e2ee/prekey_api.dart';
import 'package:keepsy/e2ee/prekey_bundle.dart';
import 'package:keepsy/e2ee/x3dh_session.dart';
import 'package:keepsy/secure_store/key_handle_adapter.dart';

import '../_sodium_setup.dart';
import '../secure_store/mock_secure_key_store.dart';
import 'identity_label_map_test_helpers.dart';

// Two IdentityServices wired against an in memory MockSecureKeyStore : both
// bootstrapped fully so the responder side has IK/LK/SPK/OPK[*] handles
// available for derive(). PrekeyBundle is synthesized from the responder's
// pubs so initiate() and derive() share the same key material end to end

class _SilentPrekeyApi implements PrekeyApi {
  // Me intentionally swallow uploads in this test : me only care about the
  // local key material that bootstrap() produced
  @override
  Future<int> opkCount() async => 20;
  @override
  Future<void> replenishOpks(
      {required List<PrekeyOpk> opks, required Uint8List replenishSig}) async {}
  @override
  Future<void> rotateSpk(
      {required Uint8List spkPub,
      required Uint8List spkSig,
      required int spkTs,
      required Uint8List rotationSig}) async {}
  @override
  Future<void> upsertIdentity(
      {required Uint8List ikPub,
      required Uint8List lkPub,
      required Uint8List spkPub,
      required Uint8List spkSig,
      required int spkTs}) async {}
  @override
  Future<PrekeyBundle> fetchPrekeyBundleByHandle(String handle) =>
      throw UnimplementedError();

  @override
  Future<PrekeyBundle> fetchPrekeyBundle(String userId) async {
    throw UnimplementedError();
  }
}

Future<
    ({
      IdentityService svc,
      MockSecureKeyStore store,
      IdentityLabelMap labels
    })> _newBootstrappedSvc({DateTime? now}) async {
  final fixed = now ?? DateTime.utc(2026, 5, 4, 12);
  final store = MockSecureKeyStore();
  await store.initialize();
  final labels = makeInMemoryLabelMap();
  await labels.load();
  final svc = IdentityService(
    store: store,
    labels: labels,
    api: _SilentPrekeyApi(),
    now: () => fixed,
  );
  await svc.bootstrap();
  return (svc: svc, store: store, labels: labels);
}

// Pulls the bootstrapped responder's pubs back out so me can build a verified
// PrekeyBundle the initiator will consume. Reads through use<T> so no priv
// bytes escape the §2.1 zeroing finally
Future<({Uint8List ikPub, Uint8List lkPub, Uint8List spkPub})> _extractPubs(
    IdentityService svc) async {
  final ikPub = await svc.useIk<Uint8List>((seed) async {
    final kp = await KeyHandleAdapter.toEd25519(seed);
    return kp.publicKey;
  });
  final lkPub = await svc.useLk<Uint8List>((priv) async {
    final kp = await KeyHandleAdapter.toX25519(priv);
    return kp.publicKey;
  });
  final spkPub = await svc.useSpk<Uint8List>((priv) async {
    final kp = await KeyHandleAdapter.toX25519(priv);
    return kp.publicKey;
  });
  return (ikPub: ikPub, lkPub: lkPub, spkPub: spkPub);
}

// Pulls a specific OPK pub by idx so the initiator can target it
Future<Uint8List> _extractOpkPub(IdentityService svc, int idx) async {
  final pub = svc.tryUseOpk<Uint8List>(idx, (priv) async {
    final kp = await KeyHandleAdapter.toX25519(priv);
    return kp.publicKey;
  });
  if (pub == null) {
    throw StateError('opk $idx missing on responder');
  }
  return pub;
}

// Synthesizes a server style verified bundle for 'svc''s identity. Signs the
// SPK under svc's IK so PrekeyBundle.verify passes
Future<PrekeyBundle> _buildVerifiedBundle({
  required IdentityService svc,
  required int spkTs,
  ({int idx, Uint8List keyPub})? opk,
}) async {
  final pubs = await _extractPubs(svc);
  final msg = Uint8List(40);
  msg.setRange(0, 32, pubs.spkPub);
  ByteData.sublistView(msg, 32).setUint64(0, spkTs, Endian.big);
  final spkSig = await svc.useIk<Uint8List>((seed) async {
    final kp = await KeyHandleAdapter.toEd25519(seed);
    return Sign.sign(kp, msg);
  });
  final json = <String, dynamic>{
    'user_id': '11111111-2222-3333-4444-555555555555',
    'ik_pub': base64Encode(pubs.ikPub),
    'lk_pub': base64Encode(pubs.lkPub),
    'spk_pub': base64Encode(pubs.spkPub),
    'spk_sig': base64Encode(spkSig),
    'spk_ts': spkTs,
  };
  if (opk != null) {
    json['opk'] = {
      'idx': opk.idx,
      'key_pub': base64Encode(opk.keyPub),
    };
  }
  return PrekeyBundle.fromJson(json);
}

void main() {
  setUpAll(ensureSodium);

  final albumId = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
  final fixed = DateTime.utc(2026, 5, 4, 12);
  final spkTs = fixed.millisecondsSinceEpoch ~/ 1000;

  group('X3dhSession.initiate', () {
    test('produces a 32B sharedSecret and a 32B ekPub (4-DH)', () async {
      final aliceSvc = (await _newBootstrappedSvc(now: fixed)).svc;
      final bobSvc = (await _newBootstrappedSvc(now: fixed)).svc;
      final opkPub = await _extractOpkPub(bobSvc, 3);
      final bundle = await _buildVerifiedBundle(
          svc: bobSvc, spkTs: spkTs, opk: (idx: 3, keyPub: opkPub));

      final result = await X3dhSession.initiate(
        bundle: bundle,
        albumId: albumId,
        identity: aliceSvc,
      );

      expect(result.sharedSecret.length, 32);
      expect(result.ekPub.length, 32);
      expect(result.opkIdx, 3);
    });

    test(
        'emits a fresh ekPub and never persists EK (no keepsy.ek.* label '
        'after the call)', () async {
      final aliceR = await _newBootstrappedSvc(now: fixed);
      final bobSvc = (await _newBootstrappedSvc(now: fixed)).svc;
      final bundle = await _buildVerifiedBundle(svc: bobSvc, spkTs: spkTs);

      final r1 = await X3dhSession.initiate(
          bundle: bundle, albumId: albumId, identity: aliceR.svc);
      final r2 = await X3dhSession.initiate(
          bundle: bundle, albumId: albumId, identity: aliceR.svc);

      // Two calls produce different EKs (fresh per call) and different shared
      // secrets (DH3 randomized through EK)
      expect(r1.ekPub, isNot(orderedEquals(r2.ekPub)));
      expect(r1.sharedSecret, isNot(orderedEquals(r2.sharedSecret)));

      // No EK label leaked into the label map or the secure store
      expect(aliceR.labels.labelsWithPrefix('keepsy.ek').length, 0);
      final ekHandles = await aliceR.store.list(labelPrefix: 'keepsy.ek');
      expect(ekHandles, isEmpty);
    });
  });

  group('X3dhSession round-trip', () {
    test('initiate + derive agree on the shared secret (4-DH)', () async {
      final aliceSvc = (await _newBootstrappedSvc(now: fixed)).svc;
      final bobSvc = (await _newBootstrappedSvc(now: fixed)).svc;
      // idx within the bootstrap pool (0..kBootstrapOpkPool-1)
      final opkIdx = 3;
      final opkPub = await _extractOpkPub(bobSvc, opkIdx);
      final bundle = await _buildVerifiedBundle(
          svc: bobSvc, spkTs: spkTs, opk: (idx: opkIdx, keyPub: opkPub));

      // Initiator needs alice's LK pub on the wire too (so bob can build the
      // X3DH info string). Pull it the same way derive() will need it
      final alicePubs = await _extractPubs(aliceSvc);

      final init = await X3dhSession.initiate(
          bundle: bundle, albumId: albumId, identity: aliceSvc);
      final responderShared = await X3dhSession.derive(
        identity: bobSvc,
        ekPub: init.ekPub,
        peerLkPub: alicePubs.lkPub,
        opkIdx: init.opkIdx,
        albumId: albumId,
      );

      expect(init.sharedSecret, orderedEquals(responderShared));
    });

    test(
        'initiate falls through to 3-DH when bundle.opk is null and round-'
        'trips with derive(opkIdx: null)', () async {
      final aliceSvc = (await _newBootstrappedSvc(now: fixed)).svc;
      final bobSvc = (await _newBootstrappedSvc(now: fixed)).svc;
      final bundle = await _buildVerifiedBundle(svc: bobSvc, spkTs: spkTs);

      final alicePubs = await _extractPubs(aliceSvc);
      final init = await X3dhSession.initiate(
          bundle: bundle, albumId: albumId, identity: aliceSvc);
      expect(init.opkIdx, isNull);

      final responderShared = await X3dhSession.derive(
        identity: bobSvc,
        ekPub: init.ekPub,
        peerLkPub: alicePubs.lkPub,
        opkIdx: null,
        albumId: albumId,
      );
      expect(init.sharedSecret, orderedEquals(responderShared));
    });
  });

  group('X3dhSession.derive', () {
    test('throws OpkNotFoundException for an opkIdx with no local label',
        () async {
      final aliceSvc = (await _newBootstrappedSvc(now: fixed)).svc;
      final bobSvc = (await _newBootstrappedSvc(now: fixed)).svc;
      final alicePubs = await _extractPubs(aliceSvc);

      // Generate a throwaway EK pub for the call : derive should fail before
      // it touches the math
      final ekKp = await Kex.generateX25519();
      final ekPub = ekKp.publicKey;

      await expectLater(
        X3dhSession.derive(
          identity: bobSvc,
          ekPub: ekPub,
          peerLkPub: alicePubs.lkPub,
          opkIdx: 999, // bootstrap only seeds 0..19
          albumId: albumId,
        ),
        throwsA(isA<OpkNotFoundException>().having((e) => e.idx, 'idx', 999)),
      );
    });
  });

  group('X3dhSession bundle verification integration', () {
    test('initiate accepts a freshly verify()d bundle', () async {
      final aliceSvc = (await _newBootstrappedSvc(now: fixed)).svc;
      final bobSvc = (await _newBootstrappedSvc(now: fixed)).svc;
      final bundle = await _buildVerifiedBundle(svc: bobSvc, spkTs: spkTs);

      // Caller responsibility : verify before initiate. No exception means OKAA
      await bundle.verify(now: () => fixed);
      final r = await X3dhSession.initiate(
          bundle: bundle, albumId: albumId, identity: aliceSvc);
      expect(r.sharedSecret.length, 32);
    });
  });
}
