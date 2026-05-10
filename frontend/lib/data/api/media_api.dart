import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:keepsy/e2ee/file_pipeline.dart';

import 'api_client.dart';

// Media HTTP surface (§5.1). The encryption + DEK wrap happens in
// FilePipeline : this layer is only HTTP plumbing : ask for an upload URL,
// PUT to S3, confirm. It's in lib/data/api/ since it touches package:http
// and the bearer auth pipeline : lib/e2ee/ stays free of those imports

class MediaApi {
  final ApiClient _api;
  // S3 PUT goes through bare http.Client : the presigned URL carries auth
  // already (no Bearer header needed) and ApiClient would helpfully retry on
  // 401 which is not what we want against S3
  final http.Client _http;

  MediaApi(this._api, {http.Client? raw}) : _http = raw ?? http.Client();

  // RequestUploadResponse mirrors the server's response shape
  Future<_RequestUploadResponse> _requestUploadURL({
    required String albumId,
    required UploadEnvelope env,
  }) async {
    final resp = await _api.post(
      '/albums/$albumId/media/upload-url',
      body: {
        'media_id': env.mediaIdString,
        'blob_size': env.blobSize,
        'blob_sha256': base64Encode(env.blobSha256),
        'mime_type': env.mimeType ?? '',
        'media_type': env.mediaType,
        'wrap_nonce': base64Encode(env.wrapNonce),
        'wrap_tag_ct': base64Encode(env.wrapTagCT),
        'epoch_tag': env.epoch,
      },
    );
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final headers = (body['required_header'] as Map<String, dynamic>? ?? {})
        .map((k, v) => MapEntry(k, v.toString()));
    return _RequestUploadResponse(
      mediaId: body['media_id'] as String,
      uploadURL: body['upload_url'] as String,
      requiredHeader: headers,
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
    await _confirmUpload(albumId, pre.mediaId);
    return pre.mediaId;
  }

  Future<List<dynamic>> listMedia(String albumId) async {
    final resp = await _api.get('/albums/$albumId/media');
    return jsonDecode(resp.body) as List<dynamic>;
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
  const _RequestUploadResponse({
    required this.mediaId,
    required this.uploadURL,
    required this.requiredHeader,
  });
}
