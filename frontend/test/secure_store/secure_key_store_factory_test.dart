import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/secure_store/key_store_exceptions.dart';
import 'package:keepsy/secure_store/secure_key_store.dart';

void main() {
  // Host platform here is Linux (CI/dev box) : factory must refuse non iOS/Android
  test('createSecureKeyStore throws PlatformUnsupportedException on host', () {
    expect(() => createSecureKeyStore(),
        throwsA(isA<PlatformUnsupportedException>()));
  });
}
