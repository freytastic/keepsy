import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/domain/account/local_identity.dart';
import 'package:keepsy/e2ee/identity_label_map.dart';

import '../../_sodium_setup.dart';
import '../../secure_store/mock_secure_key_store.dart';

void main() {
  late MockSecureKeyStore store;

  setUpAll(() async => ensureSodium());

  setUp(() async {
    store = MockSecureKeyStore();
    await store.initialize();
  });

  test('reports no identity on an empty vault', () async {
    final got = await readLocalIdentity(store);
    expect(got.ik, isNull);
    expect(got.lk, isNull);
  });

  // iOS can preserve keystore keys after the label-map sidecar is removed
  test('derives both public keys from the stored seeds alone', () async {
    final ik = await Sign.generateEd25519();
    final lk = await Kex.generateX25519();
    await store.put(kLabelIK, ik.seed);
    await store.put(kLabelLK, lk.privateKey);

    final got = await readLocalIdentity(store);

    expect(got.ik, ik.publicKey);
    expect(got.lk, lk.publicKey);
  });

  test('reports the key present in a partial identity', () async {
    final ik = await Sign.generateEd25519();
    await store.put(kLabelIK, ik.seed);

    final got = await readLocalIdentity(store);

    expect(got.ik, isA<Uint8List>());
    expect(got.lk, isNull);
  });
}
