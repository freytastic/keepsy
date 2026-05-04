import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/secure_store/key_store_exceptions.dart';

void main() {
  group('KeyStoreException hierarchy', () {
    test('all subtypes are KeyStoreException', () {
      expect(KeyTamperException(), isA<KeyStoreException>());
      expect(KeyNotFoundException('h'), isA<KeyStoreException>());
      expect(KeyStoreUninitializedException(), isA<KeyStoreException>());
      expect(PlatformUnsupportedException('linux'), isA<KeyStoreException>());
      expect(
          NativeKeyStoreException('m', 'E_X', 'msg'), isA<KeyStoreException>());
    });

    test('fromPlatform routes by code', () {
      final pe1 = PlatformException(code: 'E_KEY_TAMPER', message: 'corrupt');
      expect(KeyStoreException.fromPlatform('getOnce', pe1),
          isA<KeyTamperException>());

      final pe2 =
          PlatformException(code: 'E_KEY_NOT_FOUND', message: 'no such');
      expect(KeyStoreException.fromPlatform('getOnce', pe2),
          isA<KeyNotFoundException>());

      final pe3 =
          PlatformException(code: 'E_STORE_UNINITIALIZED', message: 'init');
      expect(KeyStoreException.fromPlatform('put', pe3),
          isA<KeyStoreUninitializedException>());

      final pe4 = PlatformException(code: 'E_NATIVE', message: 'something');
      final mapped = KeyStoreException.fromPlatform('put', pe4);
      expect(mapped, isA<NativeKeyStoreException>());
      expect((mapped as NativeKeyStoreException).method, 'put');
      expect(mapped.code, 'E_NATIVE');
    });

    test('unknown code falls back to NativeKeyStoreException', () {
      final pe = PlatformException(code: 'E_TOTALLY_NEW', message: '');
      expect(KeyStoreException.fromPlatform('list', pe),
          isA<NativeKeyStoreException>());
    });
  });
}
