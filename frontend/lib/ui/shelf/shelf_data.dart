import 'package:flutter/foundation.dart';
import 'package:keepsy/data/models/album_summary.dart';

abstract class ShelfCovers implements Listenable {
  Uint8List? bytes(String albumId, int slot);

  void ensureCover(String albumId, List<PreviewMedia> preview);

  void ensureRiffle(String albumId, List<PreviewMedia> preview);

  // Drops plaintext while preserving the reload registry
  void suspend();

  void resume();

  // Invalidates and drains album loads before cache deletion
  Future<void> forget(String albumId);
}

// Device local read state that never leaves the phone
abstract class SeenStore implements Listenable {
  int lastSeen(String albumId);

  // Distinguishes an empty known album from an unknown album
  bool knows(String albumId);

  Future<void> markSeen(String albumId, int generation);

  Future<void> forget(String albumId);
}

class InMemorySeenStore extends ChangeNotifier implements SeenStore {
  final Map<String, int> _seen = {};

  @override
  int lastSeen(String albumId) => _seen[albumId] ?? 0;

  @override
  bool knows(String albumId) => _seen.containsKey(albumId);

  @override
  Future<void> markSeen(String albumId, int generation) async {
    final cur = _seen[albumId];
    if (cur != null && cur >= generation) return;
    _seen[albumId] = generation;
    notifyListeners();
  }

  @override
  Future<void> forget(String albumId) async {
    if (_seen.remove(albumId) == null) return;
    notifyListeners();
  }
}
