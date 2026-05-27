import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/handle.dart';

void main() {
  group('normalizeHandle', () {
    // These (input → canonical) pairs are byte-identical to the Go codec's
    // handle_test.go vectors: cross language parity is the contract yk
    const vectors = {
      'K7F29QXM': 'K7F29QXM',
      'k7f2-9qxm': 'K7F29QXM',
      'ILOl0o1i': '11010011',
      '  abcd efgh ': 'ABCDEFGH',
      '0123-4567': '01234567',
    };

    vectors.forEach((input, want) {
      test('normalizes "$input" -> $want', () {
        expect(normalizeHandle(input), want);
      });
    });

    for (final bad in [
      '',
      'ABC',
      'ABCDEFGHI',
      'ABCDEFGU',
      'ABCDEF!@',
      '1234567'
    ]) {
      test('rejects "$bad"', () {
        expect(() => normalizeHandle(bad), throwsFormatException);
      });
    }
  });

  group('formatHandle', () {
    test('inserts dash and round-trips', () {
      expect(formatHandle('ABCDEFGH'), 'ABCD-EFGH');
      expect(normalizeHandle(formatHandle('ABCDEFGH')), 'ABCDEFGH');
    });
  });
}
