import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'android_keystore.dart';
import 'ios_secure_enclave.dart';
import 'key_handle.dart';
import 'key_store_exceptions.dart';

//  primary role is to manage private key material as non extractable
// handles, ensuring that raw bytes only exist in the Dart heap for the
// duration of a specific cryptographic operation
abstract class SecureKeyStore {
  Future<void> initialize();

  Future<KeyHandle> put(String label, Uint8List plaintext);

  // buffer is  guaranteed to be overwritten with zeros immediately after [fn] returns,
  // whether it succeeds or throws
  Future<T> use<T>(KeyHandle h, Future<T> Function(Uint8List bytes) fn);

  // itpermanently removes the key material associated with [h] from the store
  Future<void> delete(KeyHandle h);

  Future<List<KeyHandle>> list({String? labelPrefix});

  // dels the master wrapper key and the entire envelope
  //  an irreversible operation that invalidates all prior handles
  Future<void> wipeAll();

  @visibleForTesting
  Future<Uint8List> getOnce(KeyHandle h);
}

SecureKeyStore createSecureKeyStore() {
  if (Platform.isAndroid) return AndroidKeystore();
  if (Platform.isIOS) return IosSecureEnclave();
  throw PlatformUnsupportedException(Platform.operatingSystem);
}
