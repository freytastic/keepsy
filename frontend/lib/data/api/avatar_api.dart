import 'dart:convert';
import 'dart:typed_data';

import 'package:keepsy/data/models/avatar_ref.dart';
import 'package:keepsy/e2ee/sealed_avatar.dart';

import 'api_client.dart';
import 's3_transport.dart';

// Reserve, PUT, confirm. The server swaps the avatar in only after it has
// checked the stored object against the reserved size and hash
class AvatarApi {
  final ApiClient _api;
  final S3Transport _s3;

  AvatarApi(this._api, {S3Transport? transport})
      : _s3 = transport ?? S3Transport();

  Future<void> upload(String albumId, SealedAvatar avatar) async {
    final resp =
        await _api.post('/albums/$albumId/members/me/avatar/upload-url', body: {
      'avatar_id': avatar.avatarId,
      'blob_size': avatar.blob.length,
      'blob_sha256': base64Encode(avatar.blobSha256),
      'key_ct': base64Encode(avatar.keyCt),
    });
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final headers = (json['required_header'] as Map<String, dynamic>? ?? {})
        .map((k, v) => MapEntry(k, v.toString()));
    final put = await _s3.put(
        Uri.parse(json['upload_url'] as String), avatar.blob, headers,
        traceFields: const {'kind': 'avatar'});
    if (put.statusCode < 200 || put.statusCode >= 300) {
      throw S3StatusException(put.statusCode);
    }
    await _api.post('/albums/$albumId/members/me/avatar/confirm',
        body: {'avatar_id': avatar.avatarId});
  }

  Future<void> remove(String albumId) =>
      _api.delete('/albums/$albumId/members/me/avatar');

  Future<Uint8List> download(String albumId, AvatarRef ref) async {
    Future<Uri> url() async {
      final resp = await _api
          .post('/albums/$albumId/avatars/${ref.avatarId}/download-url');
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return Uri.parse(json['url'] as String);
    }

    final resp = await _s3.get(await url(),
        expectedBytes: ref.blobSize,
        traceFields: const {'kind': 'avatar'},
        refreshUrl: url);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw S3StatusException(resp.statusCode);
    }
    return resp.bodyBytes;
  }

  void dispose() => _s3.close();
}
