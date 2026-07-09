import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';

// Persistent display name cache: key -> (name, fingerprint), stored as ONE JSON
// blob sealed under cache_root_key (the same device key + AEAD as the media
// cache). After load() every read is solely CPU : no album MK keystore round trip
// on the render path, so names paint instantly even on a cold start

// fingerprint is the source name_ct. A rename or a member re publishing changes
// name_ct, so a stale entry is a natural miss and gets re decrypted. its in
// the app support dir (persistent), NOT the OS evictable cache dir : we never
// want names evicted by photo churn
class NameCache {
  final File _file;
  final Uint8List _cacheKey;
  final Map<String, _Entry> _entries = {};
  Timer? _flushTimer;
  // Bumped by clear()/clearAlbum() to invalidate any queued or in flight flush
  // whose sealed snapshot is now stale : _inFlight serializes all file writes so
  // a clear() can await the last one before deleting
  int _gen = 0;
  Future<void> _inFlight = Future.value();

  static final Uint8List _aad =
      Uint8List.fromList('keepsy.name-cache-v1'.codeUnits);

  NameCache._(this._file, this._cacheKey);

  static String albumKey(String albumId) => 'a:$albumId';
  static String memberKey(String albumId, String token) => 'm:$albumId:$token';

  static Future<NameCache> open({
    File? file,
    required Uint8List cacheRootKey,
  }) async {
    final f = file ??
        File(p.join(
            (await getApplicationSupportDirectory()).path, 'keepsy_names.kec'));
    final c = NameCache._(f, cacheRootKey);
    await c._load();
    return c;
  }

  Future<void> _load() async {
    try {
      if (!await _file.exists()) return;
      final wire = await _file.readAsBytes();
      final pt = await Aead.decrypt(wire: wire, key: _cacheKey, aad: _aad);
      final map = jsonDecode(utf8.decode(pt)) as Map<String, dynamic>;
      _entries.clear();
      map.forEach((k, v) {
        final e = v as Map<String, dynamic>;
        _entries[k] = _Entry(e['n'] as String, e['f'] as String);
      });
    } catch (_) {
      // missing / corrupt / key mismatch : start empty, self heals on next put
      _entries.clear();
    }
  }

  // Cached name only if it was derived from this exact name_ct fingerprint
  String? get(String key, String fingerprint) {
    final e = _entries[key];
    if (e == null || e.fingerprint != fingerprint) return null;
    return e.name;
  }

  void put(String key, String name, String fingerprint) {
    final e = _entries[key];
    if (e != null && e.name == name && e.fingerprint == fingerprint) return;
    _entries[key] = _Entry(name, fingerprint);
    _scheduleFlush();
  }

  // Drop one album's title + all its member names (removed device wipe)
  // Hard persists: a removed member's names must be durably gone, not left to a
  // debounced flush that a kill or an old in\ flight write could defeat
  Future<void> clearAlbum(String albumId) async {
    final ak = albumKey(albumId);
    final mp = 'm:$albumId:';
    final before = _entries.length;
    _entries.removeWhere((k, _) => k == ak || k.startsWith(mp));
    if (_entries.length == before) return;
    _gen++; // invalidate any in flight flush that snapshotted the old entries
    _flushTimer?.cancel();
    try {
      await _inFlight;
    } catch (_) {}
    await flush(); // write the remaining albums (removed entries gone) now
  }

  // Wipe everything (logout). Wins any in- flight/queued flush via _gen, then
  // awaits the last write before deleting so nothing can rewrite the file after
  // The instance stays reusable (in process re login re populates it)
  Future<void> clear() async {
    _gen++;
    _flushTimer?.cancel();
    _entries.clear();
    try {
      await _inFlight;
    } catch (_) {}
    await _delete(_file);
    await _delete(File('${_file.path}.tmp'));
  }

  // Coalesce a burst of puts (eg a batch of member names) into one write
  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(flush());
    });
  }

  Future<void> flush() {
    _flushTimer?.cancel();
    final gen = _gen;
    _inFlight = _inFlight.then((_) => _write(gen));
    return _inFlight;
  }

  Future<void> _write(int gen) async {
    if (gen != _gen) return; // a clear()/clearAlbum() superseded this snapshot
    try {
      final map = <String, dynamic>{
        for (final e in _entries.entries)
          e.key: {'n': e.value.name, 'f': e.value.fingerprint},
      };
      final pt = Uint8List.fromList(utf8.encode(jsonEncode(map)));
      final sealed = await Aead.encrypt(
          version: kVerAesGcm, key: _cacheKey, plaintext: pt, aad: _aad);
      if (gen != _gen) return; // clear() raced during the seal : dont write
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsBytes(sealed, flush: true);
      if (gen != _gen) {
        await _delete(tmp);
        return;
      }
      await tmp.rename(_file.path);
    } catch (_) {
      // names re decrypt next session if the write failed
    }
  }

  Future<void> _delete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

class _Entry {
  final String name;
  final String fingerprint;
  _Entry(this.name, this.fingerprint);
}
