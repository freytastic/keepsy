import 'package:flutter/services.dart';

sealed class KeyStoreException implements Exception {
  final String message;
  const KeyStoreException(this.message);

  @override
  String toString() => '$runtimeType: $message';

  static KeyStoreException fromPlatform(String method, PlatformException e) {
    switch (e.code) {
      case 'E_KEY_TAMPER':
        return KeyTamperException(e.message ?? '');
      case 'E_KEY_NOT_FOUND':
        return KeyNotFoundException(e.message ?? '');
      case 'E_STORE_UNINITIALIZED':
        return KeyStoreUninitializedException(e.message ?? '');
      default:
        return NativeKeyStoreException(method, e.code, e.message ?? '');
    }
  }
}

class KeyTamperException extends KeyStoreException {
  KeyTamperException([super.message = 'envelope auth tag mismatch']);
}

class KeyNotFoundException extends KeyStoreException {
  KeyNotFoundException([super.message = 'handle id not found']);
}

class KeyStoreUninitializedException extends KeyStoreException {
  KeyStoreUninitializedException([super.message = 'call initialize() first']);
}

class PlatformUnsupportedException extends KeyStoreException {
  PlatformUnsupportedException(String platform)
      : super('SecureKeyStore is not supported on $platform');
}

class NativeKeyStoreException extends KeyStoreException {
  final String method;
  final String code;
  NativeKeyStoreException(this.method, this.code, super.message);
}
