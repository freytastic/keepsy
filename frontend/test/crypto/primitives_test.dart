import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:cryptography/cryptography.dart' as cg;
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';

void main() {
  group('Aead round-trip', () {
    final key = Uint8List.fromList(List.filled(32, 0x42));
    final aad = Uint8List.fromList([1, 2, 3]);
    final pt = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);

    test('AES-256-GCM (VER=0x01)', () async {
      final wire = await Aead.encrypt(
          version: kVerAesGcm, key: key, plaintext: pt, aad: aad);
      expect(wire[0], equals(kVerAesGcm));
      expect(wire.length, equals(kHeaderLen + pt.length));

      final got = await Aead.decrypt(wire: wire, key: key, aad: aad);
      expect(got, orderedEquals(pt));
    });

    test('ChaCha20-Poly1305 (VER=0x02)', () async {
      final wire = await Aead.encrypt(
          version: kVerChaPo, key: key, plaintext: pt, aad: aad);
      expect(wire[0], equals(kVerChaPo));
      final got = await Aead.decrypt(wire: wire, key: key, aad: aad);
      expect(got, orderedEquals(pt));
    });

    test('empty plaintext round-trips', () async {
      final wire = await Aead.encrypt(
          version: kVerAesGcm,
          key: key,
          plaintext: Uint8List(0),
          aad: Uint8List(0));
      final got = await Aead.decrypt(wire: wire, key: key, aad: Uint8List(0));
      expect(got.length, equals(0));
    });

    test('two encryptions with the same key produce different nonces',
        () async {
      final w1 = await Aead.encrypt(
          version: kVerAesGcm, key: key, plaintext: pt, aad: aad);
      final w2 = await Aead.encrypt(
          version: kVerAesGcm, key: key, plaintext: pt, aad: aad);
      final n1 = WireFormat.parse(w1).nonce;
      final n2 = WireFormat.parse(w2).nonce;
      expect(n1, isNot(orderedEquals(n2)));
    });
  });

  group('Aead failures', () {
    final key = Uint8List.fromList(List.filled(32, 0x11));
    final pt = Uint8List.fromList([1, 2, 3]);

    test('tampered tag throws AeadAuthFailed', () async {
      final wire = await Aead.encrypt(
          version: kVerAesGcm, key: key, plaintext: pt, aad: Uint8List(0));
      // Flip a bit in the tag region (bytes 13..28)
      wire[15] ^= 0x01;
      expect(
        () => Aead.decrypt(wire: wire, key: key, aad: Uint8List(0)),
        throwsA(isA<AeadAuthFailed>()),
      );
    });

    test('wrong AAD throws AeadAuthFailed', () async {
      final wire = await Aead.encrypt(
          version: kVerAesGcm,
          key: key,
          plaintext: pt,
          aad: Uint8List.fromList([0xAA]));
      expect(
        () =>
            Aead.decrypt(wire: wire, key: key, aad: Uint8List.fromList([0xBB])),
        throwsA(isA<AeadAuthFailed>()),
      );
    });

    test('wrong key throws AeadAuthFailed', () async {
      final wire = await Aead.encrypt(
          version: kVerAesGcm, key: key, plaintext: pt, aad: Uint8List(0));
      final wrongKey = Uint8List.fromList(List.filled(32, 0x22));
      expect(
        () => Aead.decrypt(wire: wire, key: wrongKey, aad: Uint8List(0)),
        throwsA(isA<AeadAuthFailed>()),
      );
    });

    test('VER=0x03 wire throws UnimplementedError pointing at Phase 5',
        () async {
      // Build a syntactically valid but never real VER=0x03 wire
      final fake = Uint8List(kHeaderLen)..[0] = kVerStreamGcm;
      expect(
        () => Aead.decrypt(wire: fake, key: key, aad: Uint8List(0)),
        throwsA(isA<UnimplementedError>()),
      );
    });

    test('rejects wrong-size key on encrypt', () async {
      expect(
        () => Aead.encrypt(
            version: kVerAesGcm,
            key: Uint8List(31),
            plaintext: pt,
            aad: Uint8List(0)),
        throwsArgumentError,
      );
    });

    test('rejects unknown VER on encrypt', () async {
      expect(
        () => Aead.encrypt(
            version: 0xAB, key: key, plaintext: pt, aad: Uint8List(0)),
        throwsA(anyOf(isA<FormatException>(), isA<ArgumentError>())),
      );
    });
  });

  group('Hkdf', () {
    test('derives 32 bytes deterministically', () async {
      final ikm = Uint8List.fromList(List.filled(32, 0x33));
      final salt = Uint8List.fromList('test-salt'.codeUnits);
      final info = Uint8List.fromList('test-info'.codeUnits);

      final a = await Hkdf.derive(ikm: ikm, salt: salt, info: info, length: 32);
      final b = await Hkdf.derive(ikm: ikm, salt: salt, info: info, length: 32);
      expect(a, orderedEquals(b));
      expect(a.length, equals(32));
    });

    test('different info → different output (domain separation)', () async {
      final ikm = Uint8List.fromList(List.filled(32, 0x33));
      final salt = Uint8List.fromList([1, 2, 3]);
      final a = await Hkdf.derive(
          ikm: ikm,
          salt: salt,
          info: Uint8List.fromList('a'.codeUnits),
          length: 32);
      final b = await Hkdf.derive(
          ikm: ikm,
          salt: salt,
          info: Uint8List.fromList('b'.codeUnits),
          length: 32);
      expect(a, isNot(orderedEquals(b)));
    });
  });

  group('Sign (Ed25519)', () {
    test('sign/verify happy path', () async {
      final kp = await Sign.generateEd25519();
      final pk = await kp.extractPublicKey() as cg.SimplePublicKey;
      final msg = Uint8List.fromList('hello world'.codeUnits);
      final sig = await Sign.sign(kp, msg);
      expect(sig.length, equals(64));
      expect(await Sign.verify(pk, msg, sig), isTrue);
    });

    test('verify rejects tampered message', () async {
      final kp = await Sign.generateEd25519();
      final pk = await kp.extractPublicKey() as cg.SimplePublicKey;
      final msg = Uint8List.fromList([1, 2, 3]);
      final sig = await Sign.sign(kp, msg);
      final tampered = Uint8List.fromList([1, 2, 4]);
      expect(await Sign.verify(pk, tampered, sig), isFalse);
    });

    test('verify rejects flipped signature bit', () async {
      final kp = await Sign.generateEd25519();
      final pk = await kp.extractPublicKey() as cg.SimplePublicKey;
      final msg = Uint8List.fromList([9, 9, 9]);
      final sig = await Sign.sign(kp, msg);
      sig[0] ^= 0x01;
      expect(await Sign.verify(pk, msg, sig), isFalse);
    });
  });

  group('Kex (X25519)', () {
    test('two parties derive the same shared secret', () async {
      final aliceKp = await Kex.generateX25519();
      final bobKp = await Kex.generateX25519();
      final aliceShared = await Kex.dh(
          aliceKp, await bobKp.extractPublicKey() as cg.SimplePublicKey);
      final bobShared = await Kex.dh(
          bobKp, await aliceKp.extractPublicKey() as cg.SimplePublicKey);
      expect(aliceShared, orderedEquals(bobShared));
      expect(aliceShared.length, equals(32));
    });
  });

  group('Csprng', () {
    test('bytes(n) returns n bytes', () {
      expect(Csprng.bytes(0).length, equals(0));
      expect(Csprng.bytes(32).length, equals(32));
      expect(Csprng.bytes(64).length, equals(64));
    });

    test('10000 96-bit nonces are all distinct (TEST-07)', () {
      final seen = <String>{};
      for (var i = 0; i < 10000; i++) {
        seen.add(Csprng.bytes(12).toString());
      }
      expect(seen.length, equals(10000));
    });

    test('rejects negative n', () {
      expect(() => Csprng.bytes(-1), throwsArgumentError);
    });

    test('u32() returns a value in [0, 2^32)', () {
      for (var i = 0; i < 100; i++) {
        final v = Csprng.u32();
        expect(v, greaterThanOrEqualTo(0));
        expect(v, lessThan(0x100000000));
      }
    });
  });
}
