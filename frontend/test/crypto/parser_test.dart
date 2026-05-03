import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:keepsy/crypto/wire_format.dart';

void main() {
  group('WireFormat.parse', () {
    test('extracts VER, NONCE, TAG, CT from a valid wire', () {
      final wire = Uint8List(1 + 12 + 16 + 4)
        ..[0] = kVerAesGcm
        ..setRange(1, 13, List.filled(12, 0xAA))
        ..setRange(13, 29, List.filled(16, 0xBB))
        ..setRange(29, 33, List.filled(4, 0xCC));

      final parsed = WireFormat.parse(wire);

      expect(parsed.version, equals(kVerAesGcm));
      expect(parsed.nonce, orderedEquals(List.filled(12, 0xAA)));
      expect(parsed.tag, orderedEquals(List.filled(16, 0xBB)));
      expect(parsed.ciphertext, orderedEquals(List.filled(4, 0xCC)));
    });

    test('accepts empty ciphertext', () {
      final wire = Uint8List(kHeaderLen)..[0] = kVerChaPo;
      final parsed = WireFormat.parse(wire);
      expect(parsed.ciphertext.length, equals(0));
    });

    test('rejects wire shorter than the header', () {
      expect(
        () => WireFormat.parse(Uint8List(kHeaderLen - 1)),
        throwsFormatException,
      );
    });

    test('rejects unknown VER byte (0x00)', () {
      final wire = Uint8List(kHeaderLen);
      expect(() => WireFormat.parse(wire), throwsFormatException);
    });

    test('rejects unknown VER byte (0xFF)', () {
      final wire = Uint8List(kHeaderLen)..[0] = 0xFF;
      expect(() => WireFormat.parse(wire), throwsFormatException);
    });

    test('accepts VER=0x03 (parser is permissive; Aead.decrypt rejects)', () {
      final wire = Uint8List(kHeaderLen)..[0] = kVerStreamGcm;
      final parsed = WireFormat.parse(wire);
      expect(parsed.version, equals(kVerStreamGcm));
    });
  });

  group('WireFormat.assemble', () {
    test('round-trips through parse', () {
      final nonce = Uint8List.fromList(List.generate(12, (i) => i));
      final tag = Uint8List.fromList(List.generate(16, (i) => i + 100));
      final ct = Uint8List.fromList([1, 2, 3, 4, 5]);

      final wire = WireFormat.assemble(
        version: kVerAesGcm,
        nonce: nonce,
        tag: tag,
        ciphertext: ct,
      );
      final parsed = WireFormat.parse(wire);

      expect(parsed.version, equals(kVerAesGcm));
      expect(parsed.nonce, orderedEquals(nonce));
      expect(parsed.tag, orderedEquals(tag));
      expect(parsed.ciphertext, orderedEquals(ct));
    });

    test('rejects wrong-size nonce', () {
      expect(
        () => WireFormat.assemble(
          version: kVerAesGcm,
          nonce: Uint8List(11),
          tag: Uint8List(16),
          ciphertext: Uint8List(0),
        ),
        throwsArgumentError,
      );
    });

    test('rejects wrong-size tag', () {
      expect(
        () => WireFormat.assemble(
          version: kVerAesGcm,
          nonce: Uint8List(12),
          tag: Uint8List(15),
          ciphertext: Uint8List(0),
        ),
        throwsArgumentError,
      );
    });

    test('rejects unknown VER', () {
      expect(
        () => WireFormat.assemble(
          version: 0x99,
          nonce: Uint8List(12),
          tag: Uint8List(16),
          ciphertext: Uint8List(0),
        ),
        throwsArgumentError,
      );
    });
  });
}
