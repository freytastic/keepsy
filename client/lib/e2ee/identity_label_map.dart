import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:miuchio/data/storage/secure_storage.dart';

// Persists key handle labels and publication sidecars in secure storage
// Kept off the SecureKeyStore on purpose : metadata, not key material

const String kIdentityLabelMapKey = 'miuchio.identity.label_map';
const String kIdentitySpkTsKey = 'miuchio.identity.spk_ts';
// Track key and OPK publication separately so a failure between /keys and
// /opks does not regenerate an identity the server already accepted
const String kIdentityPublishedKey = 'miuchio.identity.identity_published';
const String kInitialOpksPublishedKey =
    'miuchio.identity.initial_opks_published';
// Server timestamp that a recovery rotation must exceed
const String kIdentitySpkConflictKey = 'miuchio.identity.spk_conflict_ts';

const String kLabelIK = 'miuchio.ik';
const String kLabelLK = 'miuchio.lk';
const String kLabelSpkCurrent = 'miuchio.spk.current';
const String kLabelSpkPrevious = 'miuchio.spk.previous';
// Addressable key for a rotation whose server outcome is not yet known
const String kLabelSpkPending = 'miuchio.spk.pending';
// Most recent unacknowledged key, retained for delayed wraps
const String kLabelSpkArchived = 'miuchio.spk.archived';
const String kLabelOpkPrefix = 'miuchio.opk.';

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
      : _kv = kv ?? const _FssAdapter(appSecureStorage);

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

  // Persist a multi label transition as one map write
  Future<void> mutate(void Function(Map<String, String> labels) fn) async {
    _requireLoaded();
    final next = Map<String, String>.from(_map);
    fn(next);
    _map = next;
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

  Future<int?> getSpkConflictTs() async {
    final raw = await _kv.read(kIdentitySpkConflictKey);
    if (raw == null) return null;
    return int.tryParse(raw);
  }

  Future<void> setSpkConflictTs(int serverTs) =>
      _kv.write(kIdentitySpkConflictKey, serverTs.toString());

  Future<void> clearSpkConflict() => _kv.delete(kIdentitySpkConflictKey);

  // Drop every label + sidecar. Used by bootstrap recovery flows where the
  // local key state must not leak into a fresh attempt
  Future<void> clearAll() async {
    _requireLoaded();
    _map = {};
    await _kv.delete(kIdentityLabelMapKey);
    await _kv.delete(kIdentitySpkTsKey);
    await _kv.delete(kIdentityPublishedKey);
    await _kv.delete(kInitialOpksPublishedKey);
    await _kv.delete(kIdentitySpkConflictKey);
  }

  Future<void> _persist() => _kv.write(kIdentityLabelMapKey, jsonEncode(_map));
}
