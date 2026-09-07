import 'dart:io';
import 'dart:typed_data';

import 'package:keepsy/crypto/uuid_bytes.dart';
import 'package:keepsy/data/api/api_error.dart';
import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/data/api/s3_transport.dart';
import 'package:keepsy/data/storage/media_cache_manager.dart';
import 'package:keepsy/data/storage/picked_file.dart';
import 'package:keepsy/domain/upload/upload_item.dart';
import 'package:keepsy/domain/upload/upload_ports.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';

// Restricts deletion to resolved app cache roots
class PickedSourceStoreImpl implements PickedSourceStore {
  List<String>? _roots;
  final PickerStaging _staging = PickerStaging(pickerStagingDir);

  // Clears picks left by a previous run before adoption
  Future<void> sweepStaleStaging() => _staging.sweep();

  @override
  Future<Uint8List> read(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw const UploadStageException(
          UploadFailureKind.sourceMissing, 'source_missing');
    }
    return file.readAsBytes();
  }

  @override
  Future<String> adopt(String path) => _staging.adopt(path);

  @override
  Future<void> discard(String path) async {
    _roots ??= await pickerCacheRoots();
    await discardPickedFile(path, _roots!);
  }
}

class MediaPreparerImpl implements MediaPreparer {
  final AlbumKeyStore _aks;
  MediaPreparerImpl(this._aks);

  @override
  Future<int> latestEpoch(String albumId) =>
      _aks.latestEpoch(_albumBytes(albumId));

  @override
  Future<UploadEnvelope> prepare({
    required String albumId,
    required MediaId mediaId,
    required Uint8List plaintext,
    required String mimeType,
  }) async {
    final albumIdBytes = _albumBytes(albumId);
    // Recheck the epoch because rotation can occur mid batch
    final epoch = await _aks.latestEpoch(albumIdBytes);
    if (epoch < 0) {
      throw const UploadStageException(UploadFailureKind.noAlbumKey, 'no_mk');
    }
    try {
      return await FilePipeline.prepareUpload(
        aks: _aks,
        albumIdBytes: albumIdBytes,
        currentEpoch: epoch,
        plaintext: plaintext,
        mediaType: 'photo',
        mimeType: mimeType,
        mediaId: mediaId.bytes,
      );
    } on UnprocessableImageException {
      throw const UploadStageException(
          UploadFailureKind.unprocessable, 'undecodable');
    }
  }

  Uint8List _albumBytes(String albumId) {
    final b = uuidToBytes(albumId);
    if (b == null) {
      throw const UploadStageException(
          UploadFailureKind.unknown, 'bad_album_id');
    }
    return b;
  }
}

class StagedMediaUploader implements StagedUploader {
  final MediaApi _api;
  StagedMediaUploader(this._api);

  @override
  Future<Reservation> reserve(String albumId, UploadEnvelope env) async {
    final r =
        await _classified(() => _api.reserveUpload(albumId: albumId, env: env));
    return Reservation(
      uploadUrl: r.uploadURL,
      thumbUploadUrl: r.thumbUploadURL,
      handle: r,
    );
  }

  @override
  Future<void> putFile(
    String albumId,
    Reservation reservation,
    UploadEnvelope env, {
    required ProgressSink onBytes,
    required CancelToken cancel,
  }) =>
      _classified(() => _api.putFile(_wire(reservation), env,
          albumId: albumId, onBytes: onBytes, abortTrigger: cancel.future));

  @override
  Future<void> putThumb(
    String albumId,
    Reservation reservation,
    UploadEnvelope env, {
    required ProgressSink onBytes,
    required CancelToken cancel,
  }) =>
      _classified(() => _api.putThumb(_wire(reservation), env,
          albumId: albumId, onBytes: onBytes, abortTrigger: cancel.future));

  @override
  Future<int> confirm(String albumId, MediaId mediaId) =>
      _classified(() => _api.confirmUpload(albumId, mediaId.value));

  @override
  Future<bool> abort(String albumId, MediaId mediaId) =>
      _api.abortPendingUpload(albumId, mediaId.value);

  UploadReservation _wire(Reservation r) => r.handle as UploadReservation;

  Future<T> _classified<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on UploadStageException {
      rethrow;
    } catch (error) {
      throw classifyUploadError(error);
    }
  }
}

// Avoid exception messages because they may contain signed URLs
UploadStageException classifyUploadError(Object error) {
  if (error is S3StatusException) {
    final status = error.statusCode;
    // Expired signatures are reported as 403
    if (status == 403) {
      return const UploadStageException(
          UploadFailureKind.presignExpired, 'http_403');
    }
    if (status == 408 || status == 429 || status >= 500) {
      return UploadStageException(UploadFailureKind.server, 'http_$status');
    }
    return UploadStageException(UploadFailureKind.unknown, 'http_$status');
  }
  if (error is S3TransportException) {
    return UploadStageException(UploadFailureKind.transport, error.reason);
  }
  if (error is ApiError) {
    switch (error.code) {
      case 'E_EPOCH_REPLAY':
        return const UploadStageException(
            UploadFailureKind.epochStale, 'epoch_replay');
      case 'E_EPOCH_PENDING_ROTATION':
        return const UploadStageException(
            UploadFailureKind.rotationPending, 'rotation_pending');
    }
    final status = error.httpStatus;
    if (status == 408 || status == 429 || status >= 500) {
      return UploadStageException(UploadFailureKind.server, 'http_$status');
    }
    return UploadStageException(UploadFailureKind.unknown, error.code);
  }
  if (S3Transport.isTransportFailure(error)) {
    return const UploadStageException(UploadFailureKind.transport, 'transport');
  }
  return const UploadStageException(UploadFailureKind.unknown, 'unknown');
}

class UploadCacheSink implements UploadSink {
  final MediaCacheManager _cache;
  final Future<void> Function(String albumId) _refresh;
  final void Function(MediaId, Uint8List)? _onPreview;

  UploadCacheSink(this._cache, this._refresh,
      {void Function(MediaId, Uint8List)? onPreview})
      : _onPreview = onPreview;

  @override
  void onPrepared(String albumId, MediaId mediaId, Uint8List? thumbPlaintext) {
    if (thumbPlaintext != null) _onPreview?.call(mediaId, thumbPlaintext);
  }

  @override
  Future<void> seed(String albumId, UploadEnvelope env) =>
      _cache.seedFromUpload(albumId: albumId, env: env, fullToL1: false);

  @override
  Future<void> onBatchSettled(String albumId) => _refresh(albumId);
}
