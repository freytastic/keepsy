import 'dart:async';
import 'dart:typed_data';

import 'package:keepsy/e2ee/file_pipeline.dart';

import 'upload_item.dart';

class CancelToken {
  final Completer<void> _c = Completer<void>();
  bool get isCancelled => _c.isCompleted;
  Future<void> get future => _c.future;
  void cancel() {
    if (!_c.isCompleted) _c.complete();
  }
}

// Lets the coordinator classify failures without reading messages
class UploadStageException implements Exception {
  final UploadFailureKind kind;
  final String code;
  const UploadStageException(this.kind, this.code);
  @override
  String toString() => 'UploadStageException($kind, $code)';
}

// Keeps domain code independent of path_provider
abstract class PickedSourceStore {
  Future<Uint8List> read(String path);
  Future<void> discard(String path);
}

abstract class MediaPreparer {
  // Negative when no MK is installed for the album yet
  Future<int> latestEpoch(String albumId);

  Future<UploadEnvelope> prepare({
    required String albumId,
    required MediaId mediaId,
    required Uint8List plaintext,
    required String mimeType,
  });
}

class Reservation {
  final String uploadUrl;
  final String? thumbUploadUrl;
  // Opaque adapter state for retrying this reservation
  final Object? handle;

  const Reservation({
    required this.uploadUrl,
    this.thumbUploadUrl,
    this.handle,
  });
}

typedef ProgressSink = void Function(int bytesSoFar);

abstract class StagedUploader {
  // Reuses pending object keys when the envelope is unchanged
  Future<Reservation> reserve(String albumId, UploadEnvelope env);

  Future<void> putFile(
    String albumId,
    Reservation reservation,
    UploadEnvelope env, {
    required ProgressSink onBytes,
    required CancelToken cancel,
  });

  Future<void> putThumb(
    String albumId,
    Reservation reservation,
    UploadEnvelope env, {
    required ProgressSink onBytes,
    required CancelToken cancel,
  });

  Future<int> confirm(String albumId, MediaId mediaId);

  // False when the server did not acknowledge cleanup
  Future<bool> abort(String albumId, MediaId mediaId);
}

// Best effort cache and refresh hooks after upload
abstract class UploadSink {
  // Keeps the optimistic tile alive after its picked file is deleted
  void onPrepared(String albumId, MediaId mediaId, Uint8List? thumbPlaintext);
  Future<void> seed(String albumId, UploadEnvelope env);
  Future<void> onBatchSettled(String albumId);
}

class PickedSource {
  final String path;
  final String mimeType;
  const PickedSource({required this.path, this.mimeType = 'image/jpeg'});
}
