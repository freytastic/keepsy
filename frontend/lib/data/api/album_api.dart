import 'dart:convert';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/models/member_model.dart';
import 'package:keepsy/data/api/api_client.dart';

class AlbumService {
  final ApiClient _client = ApiClient();

  Future<List<AlbumModel>> getMyAlbums() async {
    try {
      final response = await _client.get('/albums');
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) => AlbumModel.fromJson(json)).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  Future<AlbumModel?> getAlbum(String id) async {
    try {
      final response = await _client.get('/albums/$id');
      if (response.statusCode == 200) {
        return AlbumModel.fromJson(jsonDecode(response.body));
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // The real title is sealed under the album MK and PATCHed in only after
  // epoch 0 bootstrap installs that MK (see create_album_screen). This POST
  // just needs a non empty placeholder name_ct : bytes that decrypt to nothing
  // and arent legacy plaintext, so resolveAlbumName shows "Untitled Album" in
  // the unlikely case the follow up PATCH never lands
  static const _placeholderNameCt = '////'; // base64 of 0xFF 0xFF 0xFF

  Future<AlbumModel?> createAlbum() async {
    try {
      final response = await _client.post(
        '/albums',
        body: {'name_ct': _placeholderNameCt},
      );
      if (response.statusCode == 201) {
        return AlbumModel.fromJson(jsonDecode(response.body));
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // PATCH the album's encrypted title (admin/co admin only, server enforced)
  Future<bool> updateAlbumNameCt(String albumId, String nameCtB64) async {
    try {
      final response = await _client.patch(
        '/albums/$albumId',
        body: {'name_ct': nameCtB64},
      );
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  // PUT the caller's own encrypted display name for one album. The server reads
  // the caller's member_token from middleware
  Future<bool> putProfileCt(String albumId, String nameCtB64) async {
    try {
      final response = await _client.put(
        '/albums/$albumId/members/me/profile-ct',
        body: {'name_ct': nameCtB64},
      );
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteAlbum(String id) async {
    try {
      final response = await _client.delete('/albums/$id');
      return response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  Future<List<AlbumMember>> listMembers(String albumId) async {
    try {
      final response = await _client.get('/albums/$albumId/members');
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((j) => AlbumMember.fromJson(j)).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  // DELETE /albums/{id}/members/{member_token}. memberToken is the caller held
  // std base64 token, it must be re encoded url safe (no padding) for the path,
  // since std base64's '/' and '+' break routing. 204 on success
  Future<bool> removeMember(String albumId, String memberToken) async {
    try {
      final raw = base64.decode(base64.normalize(memberToken));
      final tokenPath = base64Url.encode(raw).replaceAll('=', '');
      final response =
          await _client.delete('/albums/$albumId/members/$tokenPath');
      return response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }
}
