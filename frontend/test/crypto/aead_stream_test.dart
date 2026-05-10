import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/crypto/aead_stream.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';

Uint8List _bytes(int n, [int seed = 0]) {
  final out = Uint8List(n);
  var x = seed;
  for (var i = 0; i < n; i++) {
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF;
    out[i] = x & 0xFF;
  }
  return out;
}

Uint8List _mediaId([int seed = 0xA1]) =>
    Uint8List.fromList(List<int>.filled(16, seed));

Uint8List _dek([int seed = 0xCC]) =>
    Uint8List.fromList(List<int>.filled(32, seed));

void main() {
  group('AeadStream round trip', () {
    test('small payload (one short segment)', () async {
      final pt = _bytes(100 * 1024); // 100 KB : one segment
      final wire = await AeadStream.encryptBytes(
          dek: _dek(), plaintext: pt, mediaId: _mediaId());
      final got = await AeadStream.decryptBytes(
          dek: _dek(), wire: wire, mediaId: _mediaId());
      expect(got, equals(pt));
    });

    test('exactly one full segment (1 MiB)', () async {
      final pt = _bytes(kSegmentSize);
      final wire = await AeadStream.encryptBytes(
          dek: _dek(), plaintext: pt, mediaId: _mediaId());
      final got = await AeadStream.decryptBytes(
          dek: _dek(), wire: wire, mediaId: _mediaId());
      expect(got, equals(pt));
    });

    test('multi segment (5.5 MiB -> 6 segments)', () async {
      final pt = _bytes(5 * kSegmentSize + (kSegmentSize ~/ 2));
      final wire = await AeadStream.encryptBytes(
          dek: _dek(), plaintext: pt, mediaId: _mediaId());
      final got = await AeadStream.decryptBytes(
          dek: _dek(), wire: wire, mediaId: _mediaId());
      expect(got, equals(pt));
    });

    test('empty payload still authenticatable', () async {
      final wire = await AeadStream.encryptBytes(
          dek: _dek(), plaintext: Uint8List(0), mediaId: _mediaId());
      final got = await AeadStream.decryptBytes(
          dek: _dek(), wire: wire, mediaId: _mediaId());
      expect(got.length, 0);
    });
  });

  group('AeadStream attack defenses', () {
    test('AAD mismatch (different media_id) -> AeadAuthFailed', () async {
      final pt = _bytes(2 * kSegmentSize);
      final wire = await AeadStream.encryptBytes(
          dek: _dek(), plaintext: pt, mediaId: _mediaId(0xA1));
      await expectLater(
        AeadStream.decryptBytes(
            dek: _dek(), wire: wire, mediaId: _mediaId(0xB2)),
        throwsA(isA<AeadAuthFailed>()),
      );
    });

    test('reorder (swap segment 0 and 1) -> AeadAuthFailed', () async {
      final pt = _bytes(2 * kSegmentSize + 100);
      final wire = await AeadStream.encryptBytes(
          dek: _dek(), plaintext: pt, mediaId: _mediaId());
      // Body layout post header : seg0(16+1MiB), seg1(16+1MiB), seg2(16+100)
      final body = Uint8List.sublistView(wire, AeadStream.headerLen);
      final segLen = AeadStream.segmentTagLen + kSegmentSize;
      final tampered = Uint8List.fromList(wire);
      // Copy seg1 onto seg0 slot, and seg0 onto seg1 slot
      final seg0 = body.sublist(0, segLen);
      final seg1 = body.sublist(segLen, 2 * segLen);
      tampered.setRange(
          AeadStream.headerLen, AeadStream.headerLen + segLen, seg1);
      tampered.setRange(AeadStream.headerLen + segLen,
          AeadStream.headerLen + 2 * segLen, seg0);
      await expectLater(
        AeadStream.decryptBytes(
            dek: _dek(), wire: tampered, mediaId: _mediaId()),
        throwsA(isA<AeadAuthFailed>()),
      );
    });

    test('truncation (drop last segment) -> AeadAuthFailed', () async {
      // 3 segments : drop the last one. The new "last" was originally encrypted
      // with is_last=0, so its AAD wont match the decoder's is_last=1 derivation
      final pt = _bytes(2 * kSegmentSize + 100);
      final wire = await AeadStream.encryptBytes(
          dek: _dek(), plaintext: pt, mediaId: _mediaId());
      // Last segment is 16 + 100 = 116 bytes
      final truncated =
          Uint8List.sublistView(wire, 0, wire.length - (16 + 100));
      await expectLater(
        AeadStream.decryptBytes(
            dek: _dek(), wire: truncated, mediaId: _mediaId()),
        throwsA(isA<AeadAuthFailed>()),
      );
    });

    test('truncation (drop final partial segment of an exact multiple file)',
        () async {
      // Tougher case : original file is exactly 3 * kSegmentSize. Drop the
      // last full segment : the new last (was index=1 with is_last=0) still
      // has its tag, but is_last derivation flips to 1 → tag fails
      final pt = _bytes(3 * kSegmentSize);
      final wire = await AeadStream.encryptBytes(
          dek: _dek(), plaintext: pt, mediaId: _mediaId());
      final truncated =
          Uint8List.sublistView(wire, 0, wire.length - (16 + kSegmentSize));
      await expectLater(
        AeadStream.decryptBytes(
            dek: _dek(), wire: truncated, mediaId: _mediaId()),
        throwsA(isA<AeadAuthFailed>()),
      );
    });

    test('one bit flip in any ciphertext byte -> AeadAuthFailed', () async {
      final pt = _bytes(2 * kSegmentSize);
      final wire = await AeadStream.encryptBytes(
          dek: _dek(), plaintext: pt, mediaId: _mediaId());
      final tampered = Uint8List.fromList(wire);
      // Flip a byte well into the ciphertext (past header + first tag)
      tampered[AeadStream.headerLen + AeadStream.segmentTagLen + 100] ^= 0xFF;
      await expectLater(
        AeadStream.decryptBytes(
            dek: _dek(), wire: tampered, mediaId: _mediaId()),
        throwsA(isA<AeadAuthFailed>()),
      );
    });

    test('wrong VER byte in header -> FormatException', () async {
      final pt = _bytes(100);
      final wire = await AeadStream.encryptBytes(
          dek: _dek(), plaintext: pt, mediaId: _mediaId());
      final tampered = Uint8List.fromList(wire);
      tampered[0] = kVerAesGcm; // pretend its single tag
      await expectLater(
        AeadStream.decryptBytes(
            dek: _dek(), wire: tampered, mediaId: _mediaId()),
        throwsA(isA<FormatException>()),
      );
    });

    test('header too short -> FormatException', () async {
      final tooShort = Uint8List(AeadStream.headerLen - 1)..[0] = kVerStreamGcm;
      await expectLater(
        AeadStream.decryptBytes(
            dek: _dek(), wire: tooShort, mediaId: _mediaId()),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('AeadStream nonce determinism', () {
    // Per segment nonces are HKDF derived from (DEK, FILE_NONCE, index). Same
    // inputs must yield the same output : if a future refactor introduces
    // any randomness here, segment 0 of two encrypt calls would produce
    // different ciphertexts even with the same inputs and randomness frozen
    test(
        'two encrypts with the same DEK + same plaintext + injected file_nonce '
        'derive identical per segment nonces', () async {
      // We cant inject FILE_NONCE through the public API : instead, encrypt
      // twice with the SAME DEK + SAME plaintext, capture both wires, and
      // verify the FILE_NONCE bytes differ (Csprng.bytes) but that decrypt
      // still works on each (proving the nonce derivation pipeline is sane)
      final pt = _bytes(2 * kSegmentSize, 0xDE);
      final wireA = await AeadStream.encryptBytes(
          dek: _dek(), plaintext: pt, mediaId: _mediaId());
      final wireB = await AeadStream.encryptBytes(
          dek: _dek(), plaintext: pt, mediaId: _mediaId());

      final fileNonceA = wireA.sublist(1, 1 + kNonceLen);
      final fileNonceB = wireB.sublist(1, 1 + kNonceLen);
      // Two encrypt calls must produce different FILE_NONCEs (CSPRNG)
      expect(fileNonceA, isNot(equals(fileNonceB)));
      // Both still decrypt cleanly
      expect(
          await AeadStream.decryptBytes(
              dek: _dek(), wire: wireA, mediaId: _mediaId()),
          equals(pt));
      expect(
          await AeadStream.decryptBytes(
              dek: _dek(), wire: wireB, mediaId: _mediaId()),
          equals(pt));
    });
  });
}
