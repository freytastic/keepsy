import 'dart:collection';
import 'dart:typed_data';

import 'media_cache_key.dart';

// Bounded RAM-only plaintext cache cleared when the app is backgrounded

class MediaPlaintextCache {
  final int budgetBytes;
  final LinkedHashMap<MediaCacheKey, Uint8List> _map = LinkedHashMap();
  int _bytes = 0;

  MediaPlaintextCache({this.budgetBytes = 50 * 1024 * 1024});

  Uint8List? get(MediaCacheKey k) {
    final v = _map.remove(k);
    if (v == null) return null;
    _map[k] = v;
    return v;
  }

  void put(MediaCacheKey k, Uint8List bytes) {
    if (bytes.length > budgetBytes) return;
    final old = _map.remove(k);
    if (old != null) _bytes -= old.length;
    _map[k] = bytes;
    _bytes += bytes.length;
    while (_bytes > budgetBytes && _map.isNotEmpty) {
      final firstKey = _map.keys.first;
      final v = _map.remove(firstKey)!;
      _bytes -= v.length;
    }
  }

  void clearAll() {
    _map.clear();
    _bytes = 0;
  }

  // Account deletion only. Not used on pause, where a zeroed buffer could still
  // be mid decode for a visible image
  void wipe() {
    for (final v in _map.values) {
      v.fillRange(0, v.length, 0);
    }
    clearAll();
  }

  void clearAlbum(String albumId) {
    _map.removeWhere((k, v) {
      if (k.albumId == albumId) {
        _bytes -= v.length;
        return true;
      }
      return false;
    });
  }

  // Called by MediaCacheManager.invalidate : the caller has a media_id but
  // not always album_id, so scan-by-id is the cheapest correct primitive
  void removeByMediaId(String mediaId) {
    _map.removeWhere((k, v) {
      if (k.mediaId == mediaId) {
        _bytes -= v.length;
        return true;
      }
      return false;
    });
  }

  int get totalBytes => _bytes;
  int get count => _map.length;
}
