import 'upload_item.dart';

enum PauseReason { rotationPending, noAlbumKey }

class UploadItemView {
  final String id;
  final MediaId mediaId;
  final UploadPhase phase;
  final double fraction;
  final UploadFailure? failure;
  // Null after cleanup when the UI must use the captured preview
  final String? sourcePath;

  const UploadItemView({
    required this.id,
    required this.mediaId,
    required this.phase,
    required this.fraction,
    this.failure,
    this.sourcePath,
  });
}

class UploadBatchSnapshot {
  final String batchId;
  final String albumId;
  final List<UploadItemView> items;
  final int doneCount;
  final int failedCount;
  final int unprocessableCount;
  final int logicalBytesSent;
  final double? bytesPerSecond;
  final Duration? eta;
  final PauseReason? paused;
  final int mediaGeneration;

  UploadBatchSnapshot({
    required this.batchId,
    required this.albumId,
    required List<UploadItemView> items,
    required this.doneCount,
    required this.failedCount,
    required this.unprocessableCount,
    required this.logicalBytesSent,
    this.bytesPerSecond,
    this.eta,
    this.paused,
    this.mediaGeneration = 0,
  }) : items = List.unmodifiable(items);

  int get totalCount => items.length;
  bool get settled => doneCount + failedCount == totalCount;
  int get retryableCount => items
      .where((i) =>
          i.phase == UploadPhase.failed && (i.failure?.retryable ?? false))
      .length;

  double get fraction {
    if (totalCount == 0) return 0;
    final active = items
        .where((i) => !i.isFinishedPhase)
        .fold<double>(0, (sum, i) => sum + i.fraction);
    return ((doneCount + failedCount + active) / totalCount).clamp(0.0, 1.0);
  }
}

extension on UploadItemView {
  bool get isFinishedPhase =>
      phase == UploadPhase.done || phase == UploadPhase.failed;
}

class UploadState {
  final List<UploadBatchSnapshot> batches;

  UploadState(List<UploadBatchSnapshot> batches)
      : batches = List.unmodifiable(batches);

  static UploadState get empty => UploadState(const []);

  UploadBatchSnapshot? batch(String batchId) {
    for (final b in batches) {
      if (b.batchId == batchId) return b;
    }
    return null;
  }

  // Newest unsettled batch shown by the sheet and pill
  UploadBatchSnapshot? activeFor(String albumId) {
    for (final b in batches.reversed) {
      if (b.albumId == albumId && !b.settled) return b;
    }
    return null;
  }

  // Includes done items until matching server records reach the grid
  List<UploadItemView> overlaysFor(String albumId) => List.unmodifiable([
        for (final b in batches)
          if (b.albumId == albumId)
            for (final i in b.items) i,
      ]);

  bool get anyRunning => batches.any((b) => !b.settled);
}
