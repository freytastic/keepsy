import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:keepsy/domain/upload/upload_coordinator.dart';
import 'package:keepsy/domain/upload/upload_item.dart';
import 'package:keepsy/domain/upload/upload_ports.dart';
import 'package:keepsy/domain/upload/upload_snapshot.dart';
import 'package:keepsy/ui/providers/dismissal_gate.dart';

// Owns upload snapshots and optimistic previews for Flutter widgets
class UploadQueueModel extends ChangeNotifier {
  final UploadCoordinator _co;
  final Map<String, Uint8List> _previews = {};
  // Batches can settle after their album screen closes
  final DismissalGate _dismissals = DismissalGate();
  final Map<String, Set<String>> _landed = {};
  // Screens and sheets may share ownership
  final Map<String, int> _observed = {};
  final Map<String, int> _presented = {};
  bool _sweeping = false;
  UploadState _state;
  StreamSubscription<UploadState>? _sub;

  UploadQueueModel(this._co) : _state = _co.state {
    _sub = _co.stream.listen((next) {
      _state = next;
      _holdFinishedBatches();
      notifyListeners();
      _sweep();
    });
  }

  // Keeps a sheet's batch alive while it is visible
  void beginPresenting(String batchId) => _retain(_presented, batchId);

  void endPresenting(String batchId) {
    if (_release(_presented, batchId)) _sweep();
  }

  void observeAlbum(String albumId) => _retain(_observed, albumId);

  void stopObserving(String albumId) {
    if (!_release(_observed, albumId)) return;
    _landed.remove(albumId);
    _sweep();
  }

  void _retain(Map<String, int> counts, String key) =>
      counts[key] = (counts[key] ?? 0) + 1;

  // Returns true when the final holder releases
  bool _release(Map<String, int> counts, String key) {
    final n = counts[key];
    if (n == null) return false;
    if (n > 1) {
      counts[key] = n - 1;
      return false;
    }
    counts.remove(key);
    return true;
  }

  // Releases held overlays after confirmed records are rendered
  void recordsLanded(String albumId, Set<String> mediaIds) {
    _landed[albumId] = mediaIds;
    _sweep();
  }

  void requestDismiss(String batchId) {
    _dismissals.hold(batchId);
    _sweep();
  }

  // Keep successful overlays until their records land
  void _holdFinishedBatches() {
    for (final batch in _state.batches) {
      if (batch.settled && batch.failedCount == 0) {
        _dismissals.hold(batch.batchId);
      }
    }
  }

  void _sweep() {
    if (_sweeping || _dismissals.isEmpty) return;
    _sweeping = true;
    try {
      final landed = <String>{};
      final doneByBatch = <String, List<String>?>{};
      for (final batchId in _dismissals.held) {
        // Omitted entries stay held while their sheet is visible
        if (_presented.containsKey(batchId)) continue;
        final batch = _state.batch(batchId);
        if (batch == null) {
          doneByBatch[batchId] = null;
          continue;
        }
        // No visible overlays need protection
        if (!_observed.containsKey(batch.albumId)) {
          doneByBatch[batchId] = const [];
          continue;
        }
        landed.addAll(_landed[batch.albumId] ?? const {});
        doneByBatch[batchId] = [
          for (final i in batch.items)
            if (i.phase == UploadPhase.done) i.mediaId.value
        ];
      }
      final ready =
          _dismissals.release(landedMediaIds: landed, doneByBatch: doneByBatch);
      for (final batchId in ready) {
        unawaited(dismissBatch(batchId));
      }
    } finally {
      _sweeping = false;
    }
  }

  UploadState get state => _state;

  UploadBatchSnapshot? activeFor(String albumId) => _state.activeFor(albumId);
  List<UploadItemView> overlaysFor(String albumId) =>
      _state.overlaysFor(albumId);

  Uint8List? preview(MediaId id) => _previews[id.value];

  // Refuse plaintext previews the queue no longer owns
  void putPreview(MediaId id, Uint8List bytes) {
    if (!_owns(id)) return;
    _previews[id.value] = bytes;
    notifyListeners();
  }

  bool _owns(MediaId id) => _co.state.batches
      .any((b) => b.items.any((i) => i.mediaId.value == id.value));

  Future<List<PickedSource>> stage(List<PickedSource> sources) =>
      _co.stage(sources);

  String startBatch({
    required String albumId,
    required List<PickedSource> sources,
  }) =>
      _co.enqueue(albumId: albumId, sources: sources);

  Future<void> discardUnused(Iterable<String> paths) =>
      _co.discardUnused(paths);

  void retry(String itemId) => _co.retry(itemId);
  void retryFailed(String batchId) => _co.retryFailed(batchId);

  Future<void> removeFailed(String batchId) async {
    _forgetPreviewsOf(batchId, onlyFailed: true);
    await _co.removeFailed(batchId);
    _syncState();
  }

  void resumeAlbum(String albumId) => _co.resumeAlbum(albumId);
  Future<void> cancelBatch(String batchId) async {
    _forgetPreviews(batchId);
    await _co.cancelBatch(batchId);
    _syncState();
  }

  Future<void> dismissBatch(String batchId) async {
    _forgetPreviews(batchId);
    await _co.dismissBatch(batchId);
    _syncState();
  }

  // Awaited mutations must expose their final state
  void _syncState() {
    _state = _co.state;
    notifyListeners();
  }

  void _forgetPreviews(String batchId) =>
      _forgetPreviewsOf(batchId, onlyFailed: false);

  void _forgetPreviewsOf(String batchId, {required bool onlyFailed}) {
    for (final item in _co.state.batch(batchId)?.items ?? const []) {
      if (onlyFailed && item.phase != UploadPhase.failed) continue;
      _previews.remove(item.mediaId.value);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
