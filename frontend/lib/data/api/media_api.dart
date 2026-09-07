import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';

import 'package:keepsy/diagnostics/trace.dart';

import 'api_client.dart';
import 'api_error.dart';
import 's3_transport.dart';

// Keep retries within the upload UI's lifetime
const int _confirmAttempts = 3;

Duration _confirmBackoff(int attempt) => Duration(milliseconds: 400 * attempt);

// timeout() does not cancel the request, but confirmation is idempotent, so
// overlapping attempts are safe
const Duration _confirmDeadline = Duration(seconds: 15);

// Media HTTP surface (§5.1). The encryption + DEK wrap happens in
// FilePipeline : this layer is only HTTP plumbing : ask for an upload URL,
// PUT to S3, confirm. It's in lib/data/api/ since it touches package:http
// and the bearer auth pipeline : lib/e2ee/ stays free of those imports

// MediaApiInterface : the read path slice MediaCacheManager depends on
// Carved out so cache tests can stub without faking the upload pipeline
abstract class MediaApiInterface {
  Future<List<MediaRecord>> listMedia(String albumId);
  Future<String> requestDownloadURL(String albumId, String mediaId,
      {String asset = 'file'});
  Future<Uint8List> downloadCiphertext(String url,
      {int expectedBytes, Future<String> Function()? refreshUrl});
}

class MediaApi implements MediaApiInterface {
  final ApiClient _api;
  // Presigned object-store requests must not carry the API bearer token
  final S3Transport _s3;

  MediaApi(this._api, {S3Transport? transport, http.Client? raw})
      : _s3 = transport ??
            S3Transport(
              clientFactory: raw == null ? null : (() => raw),
              // An injected client cannot be recreated after a failed GET
              maxDownloadAttempts: raw == null ? 3 : 1,
            );

  // RequestUploadResponse mirrors the server's response shape. Thumb URL +
  // headers are populated only when the request carried thumb_* fields
  Future<UploadReservation> _requestUploadURL({
    required String albumId,
    required UploadEnvelope env,
  }) async {
    final body = <String, dynamic>{
      'media_id': env.mediaIdString,
      'blob_size': env.blobSize,
      'blob_sha256': base64Encode(env.blobSha256),
      'mime_type': env.mimeType ?? '',
      'media_type': env.mediaType,
      'wrap_nonce': base64Encode(env.wrapNonce),
      'wrap_tag_ct': base64Encode(env.wrapTagCT),
      'epoch_tag': env.epoch,
    };
    if (env.hasThumb) {
      body['thumb_size'] = env.thumbSize;
      body['thumb_sha256'] = base64Encode(env.thumbSha256!);
      body['thumb_wrap_nonce'] = base64Encode(env.thumbWrapNonce!);
      body['thumb_wrap_tag_ct'] = base64Encode(env.thumbWrapTagCT!);
    }
    final resp =
        await _api.post('/albums/$albumId/media/upload-url', body: body);
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final headers = (json['required_header'] as Map<String, dynamic>? ?? {})
        .map((k, v) => MapEntry(k, v.toString()));
    final thumbURL = json['thumb_upload_url'] as String?;
    final thumbHeaders =
        (json['thumb_required_header'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v.toString()));
    return UploadReservation(
      mediaId: json['media_id'] as String,
      uploadURL: json['upload_url'] as String,
      requiredHeader: headers,
      thumbUploadURL: thumbURL,
      thumbRequiredHeader: thumbHeaders,
    );
  }

  // PutToS3 sends the ciphertext to the presigned URL. S3 validates the
  // ChecksumSHA256 + ContentLength server side : a wrong byte count or wrong
  // hash gets rejected here before we ever call ConfirmUpload
  Future<void> _putToS3(
      String url, Uint8List bytes, Map<String, String> headers,
      {required Map<String, Object?> traceFields,
      UploadProgress? onBytes,
      Future<void>? abortTrigger}) async {
    final resp = await _s3.put(Uri.parse(url), bytes, headers,
        traceFields: traceFields, onBytes: onBytes, abortTrigger: abortTrigger);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      // Object-store errors may echo the signed URL, so carry only the status
      throw S3StatusException(resp.statusCode);
    }
  }

  // Confirmation is idempotent, so transient failures are safe to retry
  Future<int> _confirmUpload(String albumId, String mediaId) async {
    Object? lastError;
    for (var attempt = 1; attempt <= _confirmAttempts; attempt++) {
      final span = Trace.start('media.confirm', fields: {
        'album': Trace.id(albumId),
        'media': Trace.id(mediaId),
        'attempt': attempt,
      });
      try {
        final generation =
            await _confirmOnce(albumId, mediaId).timeout(_confirmDeadline);
        span.end(fields: {'gen': generation});
        return generation;
      } catch (error) {
        lastError = error;
        span.fail(error is ApiError
            ? 'http_${error.httpStatus}'
            : Trace.reasonOf(error));
        if (attempt == _confirmAttempts || !_isRetryableConfirm(error)) break;
        await Future<void>.delayed(_confirmBackoff(attempt));
      }
    }
    throw lastError!;
  }

  // Retry only transient responses and transport failures
  static bool _isRetryableConfirm(Object error) {
    if (error is ApiError) {
      final status = error.httpStatus;
      return status == 408 || status == 429 || status >= 500;
    }
    return S3Transport.isTransportFailure(error);
  }

  // Zero preserves compatibility with servers that return no generation
  Future<int> _confirmOnce(String albumId, String mediaId) async {
    final resp = await _api.post(
      '/albums/$albumId/media/confirm',
      body: {'media_id': mediaId},
    );
    if (resp.body.isEmpty) return 0;
    try {
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return (json['media_generation'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  // The server sweeper handles cleanup if this best-effort request fails
  Future<bool> _abortPendingUpload(String albumId, String mediaId) async {
    final span = Trace.start('media.abortPending', fields: {
      'album': Trace.id(albumId),
      'media': Trace.id(mediaId),
    });
    try {
      await _api
          .delete('/albums/$albumId/media/$mediaId/pending')
          .timeout(const Duration(seconds: 5));
      span.end();
      return true;
    } catch (error) {
      span.fail(Trace.reasonOf(error));
      return false;
    }
  }

  // Reserve also refreshes URLs for pending media
  Future<UploadReservation> reserveUpload({
    required String albumId,
    required UploadEnvelope env,
  }) =>
      _requestUploadURL(albumId: albumId, env: env);

  Future<void> putFile(
    UploadReservation reservation,
    UploadEnvelope env, {
    required String albumId,
    UploadProgress? onBytes,
    Future<void>? abortTrigger,
  }) =>
      _putToS3(
          reservation.uploadURL, env.cipherBytes, reservation.requiredHeader,
          traceFields: {
            'album': Trace.id(albumId),
            'media': Trace.id(env.mediaIdString),
            'asset': 'file',
          },
          onBytes: onBytes,
          abortTrigger: abortTrigger);

  Future<void> putThumb(
    UploadReservation reservation,
    UploadEnvelope env, {
    required String albumId,
    UploadProgress? onBytes,
    Future<void>? abortTrigger,
  }) =>
      _putToS3(reservation.thumbUploadURL!, env.thumbCipherBytes!,
          reservation.thumbRequiredHeader,
          traceFields: {
            'album': Trace.id(albumId),
            'media': Trace.id(env.mediaIdString),
            'asset': 'thumb',
          },
          onBytes: onBytes,
          abortTrigger: abortTrigger);

  Future<int> confirmUpload(String albumId, String mediaId) =>
      _confirmUpload(albumId, mediaId);

  // The server sweeper handles unacknowledged aborts
  Future<bool> abortPendingUpload(String albumId, String mediaId) =>
      _abortPendingUpload(albumId, mediaId);

  Future<UploadResult> upload({
    required String albumId,
    required UploadEnvelope envelope,
  }) async {
    final span = Trace.start('media.uploadFlow', fields: {
      'album': Trace.id(albumId),
      'media': Trace.id(envelope.mediaIdString),
      'bytes': envelope.blobSize,
      'thumb': envelope.hasThumb,
    });
    UploadReservation? pre;
    // After confirmation starts, its outcome is ambiguous; let the server
    // sweeper handle any remaining pending row
    var confirmAttempted = false;
    try {
      pre = await reserveUpload(albumId: albumId, env: envelope);
      await putFile(pre, envelope, albumId: albumId);
      if (envelope.hasThumb && pre.thumbUploadURL != null) {
        await putThumb(pre, envelope, albumId: albumId);
      }
      confirmAttempted = true;
      final generation = await _confirmUpload(albumId, pre.mediaId);
      span.end(fields: {'gen': generation});
      return UploadResult(mediaId: pre.mediaId, mediaGeneration: generation);
    } catch (e) {
      span.fail(Trace.reasonOf(e), fields: {'confirmed': confirmAttempted});
      if (pre != null && !confirmAttempted) {
        await _abortPendingUpload(albumId, pre.mediaId);
      }
      rethrow;
    }
  }

  @override
  Future<List<MediaRecord>> listMedia(String albumId) async {
    final resp = await _api.get('/albums/$albumId/media');
    final raw =
        (jsonDecode(resp.body) as List<dynamic>).cast<Map<String, dynamic>>();
    return raw.map(MediaRecord.fromJson).toList();
  }

  // RequestDownloadURL : POSTs for a fresh presigned GET URL. Server
  // refuses pending rows : verifies caller is a member via RequireMember
  // asset=='thumb' requests the thumb object instead of the file
  // server 404s if the row has no thumb
  @override
  Future<String> requestDownloadURL(String albumId, String mediaId,
      {String asset = 'file'}) async {
    final path = asset == 'thumb'
        ? '/albums/$albumId/media/$mediaId/download-url?asset=thumb'
        : '/albums/$albumId/media/$mediaId/download-url';
    final resp = await _api.post(path);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return body['url'] as String;
  }

  // DownloadCiphertext fetches the bytes from a presigned URL. Bypasses
  // ApiClient since the URL carries auth in the query string and we dont
  // want a Bearer header (would fail S3 sig validation) or auto refresh on 401
  @override
  Future<Uint8List> downloadCiphertext(String url,
      {int expectedBytes = 0, Future<String> Function()? refreshUrl}) async {
    final resp = await _s3.get(
      Uri.parse(url),
      expectedBytes: expectedBytes,
      refreshUrl:
          refreshUrl == null ? null : () async => Uri.parse(await refreshUrl()),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('s3 GET rejected with ${resp.statusCode}');
    }
    return resp.bodyBytes;
  }

  Future<void> deleteMedia(String albumId, String mediaId) async {
    await _api.delete('/albums/$albumId/media/$mediaId');
  }

  void dispose() => _s3.close();
}

class UploadReservation {
  final String mediaId;
  final String uploadURL;
  final Map<String, String> requiredHeader;
  final String? thumbUploadURL;
  final Map<String, String> thumbRequiredHeader;
  const UploadReservation({
    required this.mediaId,
    required this.uploadURL,
    required this.requiredHeader,
    this.thumbUploadURL,
    this.thumbRequiredHeader = const {},
  });
}

class UploadResult {
  final String mediaId;
  final int mediaGeneration;

  const UploadResult({required this.mediaId, required this.mediaGeneration});
}
