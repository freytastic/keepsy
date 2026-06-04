import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';

import 'api_client.dart';

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
  Future<Uint8List> downloadCiphertext(String url);
}

class MediaApi implements MediaApiInterface {
  final ApiClient _api;
  // S3 PUT goes through bare http.Client : the presigned URL carries auth
  // already (no Bearer header needed) and ApiClient would helpfully retry on
  // 401 which is not what we want against S3
  final http.Client _http;

  MediaApi(this._api, {http.Client? raw}) : _http = raw ?? http.Client();

  // RequestUploadResponse mirrors the server's response shape. Thumb URL +
  // headers are populated only when the request carried thumb_* fields
  Future<_RequestUploadResponse> _requestUploadURL({
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
    return _RequestUploadResponse(
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
      String url, Uint8List bytes, Map<String, String> headers) async {
    final resp = await _http.put(
      Uri.parse(url),
      headers: headers,
      body: bytes,
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('s3 PUT failed: ${resp.statusCode} ${resp.body}');
    }
  }

  Future<void> _confirmUpload(String albumId, String mediaId) async {
    await _api.post(
      '/albums/$albumId/media/confirm',
      body: {'media_id': mediaId},
    );
  }

  // Upload runs the full §5.1 sequence : presign → S3 PUT → confirm. The
  // envelope must come from FilePipeline.prepareUpload. Returns the media_id
  // committed by the server (same as env.mediaIdString unless the server
  // overrode the suggestion)
  Future<String> upload({
    required String albumId,
    required UploadEnvelope envelope,
  }) async {
    final pre = await _requestUploadURL(albumId: albumId, env: envelope);
    await _putToS3(pre.uploadURL, envelope.cipherBytes, pre.requiredHeader);
    // thumb PUT before confirm. ConfirmUpload HEADs both S3 objects
    // skipping the thumb PUT would make confirm fail + drop the pending row
    if (envelope.hasThumb && pre.thumbUploadURL != null) {
      await _putToS3(pre.thumbUploadURL!, envelope.thumbCipherBytes!,
          pre.thumbRequiredHeader);
    }
    await _confirmUpload(albumId, pre.mediaId);
    return pre.mediaId;
  }

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
  Future<Uint8List> downloadCiphertext(String url) async {
    final resp = await _http.get(Uri.parse(url));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('s3 GET failed: ${resp.statusCode} ${resp.body}');
    }
    return resp.bodyBytes;
  }

  Future<void> deleteMedia(String albumId, String mediaId) async {
    await _api.delete('/albums/$albumId/media/$mediaId');
  }

  void dispose() => _http.close();
}

class _RequestUploadResponse {
  final String mediaId;
  final String uploadURL;
  final Map<String, String> requiredHeader;
  final String? thumbUploadURL;
  final Map<String, String> thumbRequiredHeader;
  const _RequestUploadResponse({
    required this.mediaId,
    required this.uploadURL,
    required this.requiredHeader,
    this.thumbUploadURL,
    this.thumbRequiredHeader = const {},
  });
}
