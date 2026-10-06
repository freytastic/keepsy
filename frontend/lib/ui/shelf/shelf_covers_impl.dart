import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:miuchio/data/models/album_summary.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/data/storage/media_sealed_cache.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/shelf/shelf_data.dart';

class ShelfCoversImpl extends ChangeNotifier implements ShelfCovers {
  final MediaSealedCache _l2;
  // Share thumbnail fetches with the album grid
  final MediaCacheManager _cache;

  static const _maxConcurrent = 3;

  final Map<String, Uint8List> _bytes = {};
  final Map<String, List<PreviewMedia>> _preview = {};

  // Tracks every preview ID whose plaintext may still be retained
  final Map<String, Set<String>> _owned = {};
  final Set<String> _inflight = {};
  final Set<String> _failed = {};
  final List<Future<void> Function()> _queue = [];
  int _running = 0;

  // Invalidates loads started before an album wipe
  final Map<String, int> _epoch = {};

  final Map<String, Set<Future<void>>> _active = {};

  // Sequenced and awaited so registry writes cannot outlive an album
  final Map<String, Future<void>> _registryWrite = {};

  bool _suspended = false;
  bool _closed = false;

  ShelfCoversImpl({
    required MediaSealedCache sealedCache,
    required MediaCacheManager cache,
  })  : _l2 = sealedCache,
        _cache = cache;

  @override
  Uint8List? bytes(String albumId, int slot) {
    final preview = _preview[albumId];
    if (preview == null || slot >= preview.length) return null;
    return _bytes[preview[slot].mediaId];
  }

  @override
  void ensureCover(String albumId, List<PreviewMedia> preview) {
    if (preview.isEmpty) return;
    _remember(albumId, preview);
    _dropUnreferenced(albumId);
    _want(albumId, preview, 0);
  }

  @override
  void ensureRiffle(String albumId, List<PreviewMedia> preview) {
    if (preview.isEmpty) return;
    _remember(albumId, preview);
    for (var slot = 1; slot < preview.length && slot < 3; slot++) {
      _want(albumId, preview, slot);
    }
  }

  void _remember(String albumId, List<PreviewMedia> preview) {
    final ids = [for (final p in preview) p.mediaId];
    final known = _preview[albumId];
    if (known != null &&
        known.length == ids.length &&
        [for (final p in known) p.mediaId].join() == ids.join()) {
      return;
    }
    _preview[albumId] = preview;
    _owned.putIfAbsent(albumId, () => <String>{}).addAll(ids);
    final pending = _registryWrite[albumId];
    final next = pending == null
        ? _l2.setCovers(albumId, ids)
        : pending.then((_) => _l2.setCovers(albumId, ids));
    _registryWrite[albumId] = next.catchError((_) {});
  }

  void _dropUnreferenced(String albumId) {
    final owned = _owned[albumId];
    final showing = _preview[albumId];
    if (owned == null || showing == null) return;
    final keep = {for (final p in showing) p.mediaId};
    var dropped = false;
    for (final id in owned.toList()) {
      if (keep.contains(id)) continue;
      owned.remove(id);
      _failed.remove(id);
      if (_bytes.remove(id) != null) dropped = true;
    }
    if (dropped) notifyListeners();
  }

  void _want(String albumId, List<PreviewMedia> preview, int slot) {
    if (_closed || slot >= preview.length) return;
    final id = preview[slot].mediaId;
    if (_bytes.containsKey(id) ||
        _inflight.contains(id) ||
        _failed.contains(id)) {
      return;
    }
    _inflight.add(id);
    final epoch = _epoch[albumId] ?? 0;
    _enqueue(() => _track(albumId, _load(albumId, preview[slot], epoch)));
  }

  Future<void> _track(String albumId, Future<void> load) {
    final set = _active.putIfAbsent(albumId, () => <Future<void>>{});
    set.add(load);
    return load.whenComplete(() {
      set.remove(load);
      if (set.isEmpty) _active.remove(albumId);
    });
  }

  void _enqueue(Future<void> Function() task) {
    _queue.add(task);
    _drain();
  }

  void _drain() {
    while (_running < _maxConcurrent && _queue.isNotEmpty) {
      final task = _queue.removeAt(0);
      _running++;
      task().whenComplete(() {
        _running--;
        _drain();
      });
    }
  }

  bool _stale(String albumId, int epoch) => (_epoch[albumId] ?? 0) != epoch;

  bool _current(String albumId, String mediaId, int epoch) {
    if (_stale(albumId, epoch)) return false;
    final showing = _preview[albumId];
    if (showing == null) return false;
    for (final p in showing) {
      if (p.mediaId == mediaId) return true;
    }
    return false;
  }

  Future<void> _load(String albumId, PreviewMedia p, int epoch) async {
    try {
      if (_stale(albumId, epoch)) return;

      final plaintext = await _cache.getDecrypted(_recordFor(albumId, p),
          thumb: true, preview: true);
      if (!_current(albumId, p.mediaId, epoch)) return;

      if (_suspended || _closed) return;
      _bytes[p.mediaId] = plaintext;
      notifyListeners();
    } catch (_) {
      if (_current(albumId, p.mediaId, epoch)) _failed.add(p.mediaId);
    } finally {
      _inflight.remove(p.mediaId);
    }
  }

  // Shelf previews omit full file wraps
  MediaRecord _recordFor(String albumId, PreviewMedia p) => MediaRecord(
        id: p.mediaId,
        albumId: albumId,
        uploaderToken: '',
        wrapNonce: Uint8List(12),
        wrapTagCT: Uint8List(48),
        epochTag: p.epochTag,
        blobSize: 0,
        blobSha256: Uint8List(32),
        mediaType: 'photo',
        mimeType: null,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        thumbWrapNonce: p.thumbWrapNonce,
        thumbWrapTagCT: p.thumbWrapTagCT,
        thumbSize: p.thumbSize,
        thumbSha256: p.thumbSha256,
      );

  @override
  Future<void> forget(String albumId) async {
    _epoch[albumId] = (_epoch[albumId] ?? 0) + 1;
    // Fence downloads before wiping the album
    _cache.fence(albumId);
    _preview.remove(albumId);
    final owned = _owned.remove(albumId);
    if (owned != null && owned.isNotEmpty) {
      for (final id in owned) {
        _bytes.remove(id);
        _failed.remove(id);
      }
      notifyListeners();
    }
    // Drain active loads before the caller clears L2
    final active = _active[albumId];
    if (active != null && active.isNotEmpty) {
      await Future.wait(active.toList());
    }
    await _registryWrite.remove(albumId);
  }

  // Refuse wipe success until active loads finish and cover bytes are zeroed
  Future<void> shutdown({Duration wait = const Duration(seconds: 20)}) async {
    _closed = true;
    _queue.clear();
    try {
      final albums = {..._preview.keys, ..._owned.keys, ..._active.keys};
      await Future.wait([for (final id in albums) forget(id)]).timeout(wait);
    } finally {
      for (final b in _bytes.values) {
        b.fillRange(0, b.length, 0);
      }
      _bytes.clear();
      _inflight.clear();
      _failed.clear();
      notifyListeners();
    }
  }

  @override
  void suspend() {
    _suspended = true;
    if (_bytes.isEmpty) return;
    _bytes.clear();
    notifyListeners();
  }

  @override
  void resume() {
    _suspended = false;
    _failed.clear();
    for (final entry in _preview.entries) {
      _want(entry.key, entry.value, 0);
    }
  }
}
