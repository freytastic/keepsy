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
  final Set<String> _observed = {};
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

  void observeAlbum(String albumId) => _observed.add(albumId);

  void stopObserving(String albumId) {
    _observed.remove(albumId);
    _landed.remove(albumId);
    _sweep();
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
        final batch = _state.batch(batchId);
        if (batch == null) {
          doneByBatch[batchId] = null;
          continue;
        }
        // No visible overlays need protection
        if (!_observed.contains(batch.albumId)) {
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

  void putPreview(MediaId id, Uint8List bytes) {
    _previews[id.value] = bytes;
    notifyListeners();
  }

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
  }

  void resumeAlbum(String albumId) => _co.resumeAlbum(albumId);
  Future<void> cancelBatch(String batchId) async {
    _forgetPreviews(batchId);
    await _co.cancelBatch(batchId);
  }

  Future<void> dismissBatch(String batchId) async {
    _forgetPreviews(batchId);
    await _co.dismissBatch(batchId);
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
