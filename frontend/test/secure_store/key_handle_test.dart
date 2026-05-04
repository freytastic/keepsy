import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/secure_store/key_handle.dart';

void main() {
  group('KeyHandle', () {
    test('equality is by id alone', () {
      final a = KeyHandle(id: 'abc', label: 'keepsy.ik');
      final b = KeyHandle(id: 'abc', label: 'something.else');
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('inequality by id', () {
      final a = KeyHandle(id: 'abc', label: 'x');
      final b = KeyHandle(id: 'def', label: 'x');
      expect(a, isNot(equals(b)));
    });

    test('toString redacts id beyond a short prefix', () {
      final h = KeyHandle(
        id: 'abcdef0123456789abcdef0123456789',
        label: 'keepsy.ik',
      );
      final s = h.toString();
      expect(s, contains('keepsy.ik'));
      expect(s, isNot(contains('abcdef0123456789')));
    });
  });
}
