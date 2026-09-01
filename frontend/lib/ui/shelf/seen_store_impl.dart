import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/ui/shelf/shelf_data.dart';

// Seen watermarks are sealed outside the reclaimable media cache
class SealedSeenStore extends ChangeNotifier implements SeenStore {
  final File _file;
  final Uint8List _cacheKey;
  final Map<String, int> _seen = {};

  Timer? _flush;
  Future<void> _inFlight = Future.value();

  static final Uint8List _aad =
      Uint8List.fromList('keepsy.seen-store-v1'.codeUnits);

  SealedSeenStore._(this._file, this._cacheKey);

  static Future<SealedSeenStore> open({
    File? file,
    required Uint8List cacheRootKey,
  }) async {
    final f = file ??
        File(p.join(
            (await getApplicationSupportDirectory()).path, 'keepsy_seen.kec'));
    final store = SealedSeenStore._(f, cacheRootKey);
    await store._load();
    return store;
  }

  Future<void> _load() async {
    try {
      if (!await _file.exists()) return;
      final wire = await _file.readAsBytes();
      final pt = await Aead.decrypt(wire: wire, key: _cacheKey, aad: _aad);
      final map = jsonDecode(utf8.decode(pt)) as Map<String, dynamic>;
      _seen.clear();
      map.forEach((k, v) {
        final n = (v as num).toInt();
        // Zero preserves knowledge of an album seen while empty
        if (n >= 0) _seen[k] = n;
      });
    } catch (_) {
      // Fail toward showing frames as unseen
      _seen.clear();
    }
  }

  @override
  int lastSeen(String albumId) => _seen[albumId] ?? 0;

  @override
  bool knows(String albumId) => _seen.containsKey(albumId);

  @override
  Future<void> markSeen(String albumId, int generation) async {
    // Generation zero still records that an empty album is known
    final cur = _seen[albumId];
    if (cur != null && (generation <= 0 || cur >= generation)) return;
    _seen[albumId] = generation < 0 ? 0 : generation;
    notifyListeners();
    _scheduleFlush();
  }

  @override
  Future<void> forget(String albumId) async {
    if (_seen.remove(albumId) == null) return;
    notifyListeners();
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _flush?.cancel();
    _flush = Timer(const Duration(milliseconds: 400), () {
      _inFlight = _inFlight.then((_) => _write());
    });
  }

  Future<void> flush() {
    _flush?.cancel();
    _inFlight = _inFlight.then((_) => _write());
    return _inFlight;
  }

  Future<void> _write() async {
    try {
      final pt = Uint8List.fromList(utf8.encode(jsonEncode(_seen)));
      final wire = await Aead.encrypt(
          version: kVerAesGcm, key: _cacheKey, plaintext: pt, aad: _aad);
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsBytes(wire, flush: true);
      await tmp.rename(_file.path);
    } catch (_) {
      // Failed persistence may reannounce frames but cannot hide them
    }
  }

  @override
  void dispose() {
    _flush?.cancel();
    super.dispose();
  }
}
