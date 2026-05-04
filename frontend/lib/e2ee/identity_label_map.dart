import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Persisted {label -> handleId} map plus an spk_ts sidecar, backed by
// flutter_secure_storage. First real consumer of FSS in the app : the
// existing StorageService still uses SharedPreferences for the auth token
// Kept off the SecureKeyStore on purpose : metadata, not key material

const String kIdentityLabelMapKey = 'keepsy.identity.label_map';
const String kIdentitySpkTsKey = 'keepsy.identity.spk_ts';
// Two phase bootstrap : keys may exist locally before the server has accepted
// them. Tracked separately so a network blip between /keys and /opks doesnt
// strand the user on a regenerated, server rejected IK
const String kIdentityPublishedKey = 'keepsy.identity.identity_published';
const String kInitialOpksPublishedKey =
    'keepsy.identity.initial_opks_published';

// Static identity labels (D6)
const String kLabelIK = 'keepsy.ik';
const String kLabelLK = 'keepsy.lk';
const String kLabelSpkCurrent = 'keepsy.spk.current';
const String kLabelSpkPrevious = 'keepsy.spk.previous';
const String kLabelOpkPrefix = 'keepsy.opk.';

// Tiny KV abstraction so tests can swap in an in-memory fake without dragging
// in the platform channels of FlutterSecureStorage. Production wraps FSS
abstract class IdentityKv {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class _FssAdapter implements IdentityKv {
  final FlutterSecureStorage _fss;
  const _FssAdapter(this._fss);

  @override
  Future<String?> read(String key) => _fss.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _fss.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _fss.delete(key: key);
}

class IdentityLabelMap {
  final IdentityKv _kv;
  Map<String, String> _map = {};
  bool _loaded = false;

  IdentityLabelMap({IdentityKv? kv})
      : _kv = kv ?? const _FssAdapter(FlutterSecureStorage());

  Future<void> load() async {
    final raw = await _kv.read(kIdentityLabelMapKey);
    if (raw == null || raw.isEmpty) {
      _map = {};
    } else {
      final decoded = jsonDecode(raw);
      _map = (decoded as Map).map((k, v) => MapEntry(k as String, v as String));
    }
    _loaded = true;
  }

  void _requireLoaded() {
    if (!_loaded) {
      throw StateError('IdentityLabelMap.load() must be called first');
    }
  }

  String? handleId(String label) {
    _requireLoaded();
    return _map[label];
  }

  Future<void> set(String label, String handleId) async {
    _requireLoaded();
    _map[label] = handleId;
    await _persist();
  }

  Future<void> remove(String label) async {
    _requireLoaded();
    _map.remove(label);
    await _persist();
  }

  List<String> labelsWithPrefix(String prefix) {
    _requireLoaded();
    return _map.keys.where((k) => k.startsWith(prefix)).toList();
  }

  // SPK rotation cadence sidecar : kept as a separate KV entry so the labels
  // map stays a pure {label -> handleId} table
  Future<int?> getSpkTs() async {
    final raw = await _kv.read(kIdentitySpkTsKey);
    if (raw == null) return null;
    return int.tryParse(raw);
  }

  Future<void> setSpkTs(int ts) => _kv.write(kIdentitySpkTsKey, ts.toString());

  Future<bool> isIdentityPublished() async =>
      (await _kv.read(kIdentityPublishedKey)) == 'true';

  Future<void> markIdentityPublished() =>
      _kv.write(kIdentityPublishedKey, 'true');

  Future<bool> areInitialOpksPublished() async =>
      (await _kv.read(kInitialOpksPublishedKey)) == 'true';

  Future<void> markInitialOpksPublished() =>
      _kv.write(kInitialOpksPublishedKey, 'true');

  // Drop every label + sidecar. Used by bootstrap recovery flows where the
  // local key state must not leak into a fresh attempt
  Future<void> clearAll() async {
    _requireLoaded();
    _map = {};
    await _kv.delete(kIdentityLabelMapKey);
    await _kv.delete(kIdentitySpkTsKey);
    await _kv.delete(kIdentityPublishedKey);
    await _kv.delete(kInitialOpksPublishedKey);
  }

  Future<void> _persist() => _kv.write(kIdentityLabelMapKey, jsonEncode(_map));
}
