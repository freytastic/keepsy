import 'dart:typed_data';
import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/secure_store/key_handle_adapter.dart';

import '../_sodium_setup.dart';

void main() {
  setUpAll(ensureSodium);

  group('KeyHandleAdapter', () {
    test('toEd25519 reconstructs same public key as cryptography pkg (parity)',
        () async {
      final seed = Uint8List.fromList(List.generate(32, (i) => i));
      final reconstructed = await KeyHandleAdapter.toEd25519(seed);

      final ref = await cg.Ed25519().newKeyPairFromSeed(seed);
      final refPub = await ref.extractPublicKey();

      expect(reconstructed.publicKey, equals(refPub.bytes));
    });

    test('toEd25519 produces a verifiably-signing key pair', () async {
      final seed = Uint8List.fromList(List.filled(32, 0xAA));
      final kp = await KeyHandleAdapter.toEd25519(seed);
      final msg = Uint8List.fromList([1, 2, 3, 4]);
      final sig = await Sign.sign(kp, msg);
      expect(await Sign.verify(kp.publicKey, msg, sig), isTrue);
    });

    test('toX25519 reconstructs same public key as cryptography pkg (parity)',
        () async {
      final scalar = Uint8List.fromList(List.generate(32, (i) => 255 - i));
      final reconstructed = await KeyHandleAdapter.toX25519(scalar);

      final ref = await cg.X25519().newKeyPairFromSeed(scalar);
      final refPub = await ref.extractPublicKey();

      expect(reconstructed.publicKey, equals(refPub.bytes));
    });

    test('rejects wrong-length input', () async {
      await expectLater(
          KeyHandleAdapter.toEd25519(Uint8List(31)), throwsArgumentError);
      await expectLater(
          KeyHandleAdapter.toX25519(Uint8List(33)), throwsArgumentError);
    });
  });
}
