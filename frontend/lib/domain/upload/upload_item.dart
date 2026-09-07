import 'dart:typed_data';

import 'package:keepsy/crypto/uuid_bytes.dart';
import 'package:uuid/uuid.dart';

// Stores the canonical UUID and derives AEAD AAD bytes when needed
class MediaId {
  final String value;
  const MediaId._(this.value);

  factory MediaId.fresh() => MediaId._(const Uuid().v4());

  factory MediaId.parse(String s) {
    if (uuidToBytes(s) == null) throw ArgumentError('not a uuid: $s');
    return MediaId._(s);
  }

  Uint8List get bytes => uuidToBytes(value)!;

  @override
  bool operator ==(Object other) => other is MediaId && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

enum UploadPhase {
  queued,
  preparing,
  reserving,
  sendingFile,
  sendingThumb,
  confirming,
  done,
  failed,
  canceling,
}

// Manual retries reprepare unless confirmation was ambiguous
enum ResumePoint { prepare, confirm }

enum UploadFailureKind {
  transport,
  presignExpired,
  server,
  epochStale,
  rotationPending,
  noAlbumKey,
  unprocessable,
  sourceMissing,
  unknown,
}

bool pausesAlbum(UploadFailureKind kind) =>
    kind == UploadFailureKind.rotationPending ||
    kind == UploadFailureKind.noAlbumKey;

bool isTerminal(UploadFailureKind kind) =>
    kind == UploadFailureKind.unprocessable ||
    kind == UploadFailureKind.sourceMissing;

class UploadFailure {
  final UploadFailureKind kind;
  final ResumePoint resumeFrom;
  // Fixed code because exception messages may contain signed URLs
  final String code;

  const UploadFailure({
    required this.kind,
    required this.resumeFrom,
    required this.code,
  });

  bool get retryable => !isTerminal(kind);
}

class UploadItem {
  final String id;
  final String batchId;
  final String albumId;
  final MediaId mediaId;
  final String sourcePath;
  final UploadPhase phase;
  final int? payloadByteLength;
  // Excludes retransmitted bytes so progress cannot exceed 100 percent
  final int logicalBytesSent;
  final int transferAttempt;
  // Bounds repeated epoch rotation retries
  final int prepareAttempt;
  final int manualRetries;
  final UploadFailure? failure;
  final bool sourceDiscarded;

  const UploadItem({
    required this.id,
    required this.batchId,
    required this.albumId,
    required this.mediaId,
    required this.sourcePath,
    this.phase = UploadPhase.queued,
    this.payloadByteLength,
    this.logicalBytesSent = 0,
    this.transferAttempt = 0,
    this.prepareAttempt = 0,
    this.manualRetries = 0,
    this.failure,
    this.sourceDiscarded = false,
  });

  bool get isFinished =>
      phase == UploadPhase.done || phase == UploadPhase.failed;

  bool get isSending =>
      phase == UploadPhase.sendingFile || phase == UploadPhase.sendingThumb;

  UploadItem copyWith({
    UploadPhase? phase,
    int? payloadByteLength,
    int? logicalBytesSent,
    int? transferAttempt,
    int? prepareAttempt,
    int? manualRetries,
    UploadFailure? failure,
    bool clearFailure = false,
    bool? sourceDiscarded,
  }) =>
      UploadItem(
        id: id,
        batchId: batchId,
        albumId: albumId,
        mediaId: mediaId,
        sourcePath: sourcePath,
        phase: phase ?? this.phase,
        payloadByteLength: payloadByteLength ?? this.payloadByteLength,
        logicalBytesSent: logicalBytesSent ?? this.logicalBytesSent,
        transferAttempt: transferAttempt ?? this.transferAttempt,
        prepareAttempt: prepareAttempt ?? this.prepareAttempt,
        manualRetries: manualRetries ?? this.manualRetries,
        failure: clearFailure ? null : (failure ?? this.failure),
        sourceDiscarded: sourceDiscarded ?? this.sourceDiscarded,
      );
}
