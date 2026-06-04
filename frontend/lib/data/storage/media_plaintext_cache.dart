import 'dart:collection';
import 'dart:typed_data';

import 'media_cache_key.dart';

// L1 RAM cache : decrypted plaintext bytes keyed by MediaCacheKey. Bounded
// LRU, default 50 MB. Cleared by main.dart on AppLifecycleState.paused so
// a backgrounded app holds no plaintext. Strict server-blind line stays at
// AndroidKeyStore : RAM is the only place plaintext ever lives

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
