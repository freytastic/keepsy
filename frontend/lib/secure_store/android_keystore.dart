import 'package:flutter/services.dart';

import 'key_handle.dart';
import 'key_store_exceptions.dart';
import 'secure_key_store.dart';

class AndroidKeystore implements SecureKeyStore {
  static const _channel = MethodChannel('keepsy/keystore');

  @override
  Future<void> initialize() => _invoke<void>('initialize', const {});

  @override
  Future<KeyHandle> put(String label, Uint8List plaintext) async {
    final r =
        await _invoke<Map>('put', {'label': label, 'plaintext': plaintext});
    return KeyHandle(id: r['handleId'] as String, label: label);
  }

  @override
  Future<T> use<T>(KeyHandle h, Future<T> Function(Uint8List) fn) async {
    final bytes = await getOnce(h);
    try {
      return await fn(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  @override
  Future<Uint8List> getOnce(KeyHandle h) async {
    final r = await _invoke<Map>('getOnce', {'handleId': h.id});
    // Convert dynamic list from MethodChannel back to typed Uint8List
    return Uint8List.fromList((r['plaintext'] as List).cast<int>());
  }

  @override
  Future<void> delete(KeyHandle h) =>
      _invoke<void>('delete', {'handleId': h.id});

  @override
  Future<List<KeyHandle>> list({String? labelPrefix}) async {
    final r = await _invoke<List>('list', {'labelPrefix': labelPrefix});
    return r.map((e) {
      final m = e as Map;
      return KeyHandle(id: m['handleId'] as String, label: m['label'] as String);
    }).toList();
  }

  @override
  Future<void> wipeAll() => _invoke<void>('wipeAll', const {});

  /// Typed wrapper for MethodChannel.invokeMethod
  /// Maps PlatformException to typed KeyStoreException
  Future<R> _invoke<R>(String method, Map<String, Object?> args) async {
    try {
      final result = await _channel.invokeMethod<Object?>(method, args);
      return result as R;
    } on PlatformException catch (e) {
      throw KeyStoreException.fromPlatform(method, e);
    }
  }
  }
}
