import 'package:keepsy/domain/upload/upload_item.dart';
import 'package:keepsy/domain/upload/upload_snapshot.dart';

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  final mb = bytes / (1024 * 1024);
  return mb < 10 ? '${mb.toStringAsFixed(1)} MB' : '${mb.round()} MB';
}

String formatRate(double? bytesPerSecond) {
  if (bytesPerSecond == null) return '';
  final mb = bytesPerSecond / (1024 * 1024);
  if (mb >= 1) return '${mb.toStringAsFixed(1)} MB/s';
  return '${(bytesPerSecond / 1024).round()} KB/s';
}

// Rounds ETA to avoid a distracting second by second countdown
String formatEta(Duration? left) {
  if (left == null) return '';
  final s = left.inSeconds;
  if (s < 8) return 'a few seconds left';
  if (s < 90) return 'about ${(s / 5).round() * 5} seconds left';
  final m = (s / 60).round();
  return 'about $m minute${m == 1 ? '' : 's'} left';
}

String phaseLabel(UploadPhase phase) {
  switch (phase) {
    case UploadPhase.preparing:
      return 'Locking';
    case UploadPhase.reserving:
    case UploadPhase.sendingFile:
    case UploadPhase.sendingThumb:
    case UploadPhase.confirming:
      return 'Sending';
    case UploadPhase.queued:
      return 'Waiting';
    case UploadPhase.canceling:
      return 'Stopping';
    case UploadPhase.done:
      return 'Added';
    case UploadPhase.failed:
      return 'Not added';
  }
}

String sheetTitle(UploadBatchSnapshot b, String? albumName) {
  final into = albumName == null || albumName.isEmpty ? '' : ' to $albumName';
  if (b.settled) {
    if (b.doneCount == 0) return 'Nothing was added';
    final n = b.doneCount;
    final what = '$n photo${n == 1 ? '' : 's'}';
    return b.failedCount == 0 ? 'Added $what$into' : 'Added $what$into';
  }
  final n = b.totalCount;
  return 'Adding $n photo${n == 1 ? '' : 's'}$into';
}

String? pauseNote(UploadBatchSnapshot b) {
  switch (b.paused) {
    case PauseReason.rotationPending:
      return 'Waiting for this album to finish updating its keys. '
          'Your photos are held here, nothing is lost.';
    case PauseReason.noAlbumKey:
      return 'Waiting for this album’s keys to arrive on this phone.';
    case null:
      return null;
  }
}

String failureHeadline(int count) =>
    '$count photo${count == 1 ? '' : 's'} didn’t send.';

String failureBody(int count) => count == 1
    ? 'The connection dropped partway. Your photo is still here, so you can try again.'
    : 'The connection dropped partway. Your photos are still here, so you can try again.';

// The same undecodable bytes would fail every retry
String unprocessableHeadline(int count) =>
    '$count photo${count == 1 ? '' : 's'} couldn’t be opened.';

String unprocessableBody(int count) => count == 1
    ? 'This phone can’t read that photo’s format, so it was left out. Pick a different one and it will go straight up.'
    : 'This phone can’t read those formats, so they were left out. Pick different ones and they will go straight up.';
