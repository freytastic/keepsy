import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/e2ee/prekey_api.dart';
import 'package:keepsy/e2ee/prekey_bundle.dart';
import 'package:keepsy/e2ee/x3dh_session.dart';
import 'package:keepsy/secure_store/key_handle_adapter.dart';

import '../_sodium_setup.dart';
import '../secure_store/mock_secure_key_store.dart';
import 'identity_label_map_test_helpers.dart';

// D10 best effort : the session hands sharedSecret back to caller, caller
// owns the lifetime, caller is expected to fillRange(0,len,0) after use.
// This test proves the contract holds at the buffer reference level :
// zeroing the returned Uint8List actually zeros it. Heap snapshot inspection
// would need vm_service + custom harness (same trade off as §2.1's
// memory_zeroing_test.dart) and isnt worth the complexity here

class _SilentApi implements PrekeyApi {
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

Future<IdentityService> _bootstrappedSvc(DateTime now) async {
  final store = MockSecureKeyStore();
  await store.initialize();
  final labels = makeInMemoryLabelMap();
  await labels.load();
  final svc = IdentityService(
    store: store,
    labels: labels,
    api: _SilentApi(),
    now: () => now,
  );
  await svc.bootstrap();
  return svc;
}

Future<PrekeyBundle> _bundleFor(IdentityService svc, int spkTs) async {
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
  final msg = Uint8List(40);
  msg.setRange(0, 32, spkPub);
  ByteData.sublistView(msg, 32).setUint64(0, spkTs, Endian.big);
  final spkSig = await svc.useIk<Uint8List>((seed) async {
    final kp = await KeyHandleAdapter.toEd25519(seed);
    return Sign.sign(kp, msg);
  });
  return PrekeyBundle.fromJson({
    'user_id': '11111111-2222-3333-4444-555555555555',
    'ik_pub': base64Encode(ikPub),
    'lk_pub': base64Encode(lkPub),
    'spk_pub': base64Encode(spkPub),
    'spk_sig': base64Encode(spkSig),
    'spk_ts': spkTs,
  });
}

void main() {
  setUpAll(ensureSodium);

  test(
      'caller-zeroed sharedSecret stays zero and a second initiate produces '
      'a fresh non-zero secret', () async {
    final albumId = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
    final fixed = DateTime.utc(2026, 5, 4, 12);
    final spkTs = fixed.millisecondsSinceEpoch ~/ 1000;

    final aliceSvc = await _bootstrappedSvc(fixed);
    final bobSvc = await _bootstrappedSvc(fixed);
    final bundle = await _bundleFor(bobSvc, spkTs);

    final r1 = await X3dhSession.initiate(
        bundle: bundle, albumId: albumId, identity: aliceSvc);
    expect(r1.sharedSecret.length, 32);
    //  freshly derived, must not already be all zero
    expect(r1.sharedSecret.any((b) => b != 0), isTrue,
        reason: 'fresh sharedSecret should be non zero');

    // Caller zeros after use (D10 contract)
    final captured = r1.sharedSecret;
    captured.fillRange(0, captured.length, 0);
    expect(captured.every((b) => b == 0), isTrue);
    // The reference inside the result struct is the same buffer
    expect(r1.sharedSecret.every((b) => b == 0), isTrue);

    // Second initiate with completely fresh keys produces a non zero secret :
    // our zeroing didnt leave any global state poisoned
    final aliceSvc2 = await _bootstrappedSvc(fixed);
    final bobSvc2 = await _bootstrappedSvc(fixed);
    final bundle2 = await _bundleFor(bobSvc2, spkTs);
    final r2 = await X3dhSession.initiate(
        bundle: bundle2, albumId: albumId, identity: aliceSvc2);
    expect(r2.sharedSecret.any((b) => b != 0), isTrue);
  });
}
