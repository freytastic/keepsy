import 'dart:math';
import 'dart:typed_data';

import 'package:keepsy/secure_store/key_handle.dart';
import 'package:keepsy/secure_store/key_store_exceptions.dart';
import 'package:keepsy/secure_store/secure_key_store.dart';

class MockSecureKeyStore extends SecureKeyStore {
  final Map<String, _Entry> _store = {};
  bool _initialized = false;

  @override
  Future<void> initialize() async => _initialized = true;

  @override
  Future<KeyHandle> put(String label, Uint8List plaintext) async {
    _requireInit();
    final id = _randomHex(16);
    _store[id] = _Entry(label, Uint8List.fromList(plaintext));
    return KeyHandle(id: id, label: label);
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
    _requireInit();
    final e = _store[h.id];
    if (e == null) throw KeyNotFoundException(h.id);
    return Uint8List.fromList(e.value);
  }

  @override
  Future<void> delete(KeyHandle h) async {
    _requireInit();
    _store.remove(h.id);
  }

  @override
  Future<List<KeyHandle>> list({String? labelPrefix}) async {
    _requireInit();
    return _store.entries
        .where(
            (e) => labelPrefix == null || e.value.label.startsWith(labelPrefix))
        .map((e) => KeyHandle(id: e.key, label: e.value.label))
        .toList();
  }

  @override
  Future<void> wipeAll() async {
    _store.clear();
    // Mirrors real impls: caller must re'initialize()' to keep using the store
    _initialized = false;
  }

  void _requireInit() {
    if (!_initialized) throw KeyStoreUninitializedException();
  }

  static final _rng = Random.secure();
  static String _randomHex(int n) {
    final b = List<int>.generate(n, (_) => _rng.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }
}

class _Entry {
  final String label;
  final Uint8List value;
  _Entry(this.label, this.value);
}
