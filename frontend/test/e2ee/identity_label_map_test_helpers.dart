import 'package:keepsy/e2ee/identity_label_map.dart';

// Tiny in memory IdentityKv shared across the e2ee test suite
class _MemKv implements IdentityKv {
  final Map<String, String> _m = {};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> delete(String key) async => _m.remove(key);
}

IdentityLabelMap makeInMemoryLabelMap() => IdentityLabelMap(kv: _MemKv());
