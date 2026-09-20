import 'dart:io';
import 'dart:typed_data';

import 'package:keepsy/crypto/uuid_bytes.dart';
import 'package:keepsy/data/api/api_error.dart';
import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/data/api/s3_transport.dart';
import 'package:keepsy/data/storage/media_cache_manager.dart';
import 'package:keepsy/data/storage/picked_file.dart';
import 'package:keepsy/diagnostics/trace.dart';
import 'package:keepsy/data/upload/upload_outbox.dart';
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
  final UploadOutboxStore _outbox;
  // Prevents sealed media from crossing signed-in accounts
  final String? Function() _owner;
  // Null when the platform has no native image bridge
  final ImageTranscoder? _transcode;
  // Retains only the latest plaintext for immediate cache seeding
  ({String itemId, String owner, EncryptedMedia media})? _hot;

  MediaPreparerImpl(this._aks, this._outbox,
      {required String? Function() owner, ImageTranscoder? transcode})
      : _owner = owner,
        _transcode = transcode;

  @override
  Future<SealedUpload> seal({
    required String itemId,
    required String albumId,
    required MediaId mediaId,
    required Uint8List plaintext,
    required String mimeType,
  }) async {
    final owner = _owner();
    if (owner == null) {
      throw const UploadStageException(UploadFailureKind.unknown, 'no_account');
    }
    final EncryptedMedia media;
    try {
      media = await FilePipeline.encryptMedia(
        plaintext: plaintext,
        mediaType: 'photo',
        mimeType: mimeType,
        mediaId: mediaId.bytes,
        transcode: _transcode,
      );
    } on UnprocessableImageException {
      throw const UploadStageException(
          UploadFailureKind.unprocessable, 'undecodable');
    }
    try {
      await Trace.measure<void>(
        'media.outboxPut',
        () => _outbox.put(
            itemId: itemId, albumId: albumId, owner: owner, media: media),
        fields: {'bytes': media.payloadByteLength},
      );
    } catch (_) {
      media.zeroKeys();
      throw const UploadStageException(
          UploadFailureKind.unknown, 'outbox_write');
    }
    _dropHot();
    _hot = (itemId: itemId, owner: owner, media: media);
    return SealedUpload(
      itemId: itemId,
      albumId: albumId,
      mediaId: mediaId,
      payloadByteLength: media.payloadByteLength,
      thumbPreview: media.thumbPlaintext,
    );
  }

  @override
  Future<UploadEnvelope> wrap({
    required String itemId,
    required String albumId,
  }) async {
    final albumIdBytes = _albumBytes(albumId);
    // Recheck the epoch because rotation can occur mid batch
    final epoch = await _aks.latestEpoch(albumIdBytes);
    if (epoch < 0) {
      throw const UploadStageException(UploadFailureKind.noAlbumKey, 'no_mk');
    }
    final owner = _owner();
    final hot = _hot;
    EncryptedMedia? media;
    if (hot != null && hot.itemId == itemId) {
      _hot = null;
      if (hot.owner == owner) {
        media = hot.media;
      } else {
        hot.media.zeroKeys();
      }
    } else if (owner != null) {
      media = await _outbox.load(itemId, owner: owner);
    }
    if (media == null) {
      throw const UploadStageException(
          UploadFailureKind.sourceMissing, 'sealed_missing');
    }
    try {
      return await FilePipeline.wrapKeys(
        aks: _aks,
        albumIdBytes: albumIdBytes,
        epoch: epoch,
        media: media,
      );
    } finally {
      media.zeroKeys();
    }
  }

  @override
  Future<List<SealedUpload>> restore() async {
    final owner = _owner();
    if (owner == null) return const [];
    final out = <SealedUpload>[];
    for (final r in await _outbox.restore(owner)) {
      try {
        out.add(SealedUpload(
          itemId: r.itemId,
          albumId: r.albumId,
          mediaId: MediaId.parse(r.mediaId),
          payloadByteLength: r.payloadByteLength,
          thumbPreview: r.thumbPreview,
        ));
      } catch (_) {
        await _outbox.remove(r.itemId);
      }
    }
    return out;
  }

  @override
  Future<void> discardSealed(String itemId) async {
    if (_hot?.itemId == itemId) _dropHot();
    await _outbox.remove(itemId);
  }

  @override
  Future<void> discardAlbum(String albumId) async {
    _dropHot();
    await _outbox.clearAlbum(albumId);
  }

  void _dropHot() {
    _hot?.media.zeroKeys();
    _hot = null;
  }

  void wipeMemory() {
    _hot?.media.zeroAll();
    _hot = null;
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
  // Resolves this device's uploader token for seeded records
  final String? Function(String albumId) _selfToken;

  UploadCacheSink(this._cache, this._refresh,
      {required String? Function(String albumId) selfToken,
      void Function(MediaId, Uint8List)? onPreview})
      : _onPreview = onPreview,
        _selfToken = selfToken;

  @override
  void onPrepared(String albumId, MediaId mediaId, Uint8List? thumbPlaintext) {
    if (thumbPlaintext != null) _onPreview?.call(mediaId, thumbPlaintext);
  }

  @override
  Future<void> seed(String albumId, UploadEnvelope env) =>
      _cache.seedFromUpload(
        albumId: albumId,
        env: env,
        // Keep the offline record if its token is briefly unavailable
        uploaderToken: _selfToken(albumId) ?? '',
        fullToL1: false,
      );

  @override
  Future<void> onBatchSettled(String albumId) => _refresh(albumId);
}
