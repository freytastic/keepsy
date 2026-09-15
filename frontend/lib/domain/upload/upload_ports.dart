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

  // Moves a picked file into managed staging and returns its new path
  Future<String> adopt(String path);

  Future<void> discard(String path);
}

// A photo encrypted on this device under its own keys, which are sealed to a
// device key and never to an album key, so it survives a restart
class SealedUpload {
  final String itemId;
  final String albumId;
  final MediaId mediaId;
  final int payloadByteLength;
  // Decrypted for the optimistic tile, never persisted in the clear
  final Uint8List? thumbPreview;

  const SealedUpload({
    required this.itemId,
    required this.albumId,
    required this.mediaId,
    required this.payloadByteLength,
    this.thumbPreview,
  });
}

abstract class MediaPreparer {
  // Strips, encrypts and durably stores the photo. Needs no album key
  Future<SealedUpload> seal({
    required String itemId,
    required String albumId,
    required MediaId mediaId,
    required Uint8List plaintext,
    required String mimeType,
  });

  // Wraps the sealed keys under the album's newest key
  Future<UploadEnvelope> wrap({
    required String itemId,
    required String albumId,
  });

  // Photos the signed in account sealed in an earlier run
  Future<List<SealedUpload>> restore();

  Future<void> discardSealed(String itemId);

  Future<void> discardAlbum(String albumId);
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
