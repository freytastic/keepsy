import 'dart:convert';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/models/member_model.dart';
import 'package:keepsy/data/api/api_client.dart';
import 'package:keepsy/data/api/api_error.dart';
import 'package:keepsy/domain/albums/album_cleanup.dart';

class AlbumService {
  final ApiClient _client = ApiClient();

  // Null distinguishes a failed refresh from an empty shelf
  Future<List<AlbumModel>?> getMyAlbums() async {
    try {
      final response = await _client.get('/albums');
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) => AlbumModel.fromJson(json)).toList();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // Only a typed refusal counts as gone: anything else may be transient
  Future<AlbumPresence> probeAlbum(String id) async {
    try {
      final response = await _client.get('/albums/$id');
      return response.statusCode == 200
          ? AlbumPresence.member
          : AlbumPresence.unknown;
    } on ApiError catch (e) {
      return switch (e.code) {
        'E_NOT_MEMBER' || 'E_MEMBER_REVOKED' => AlbumPresence.gone,
        _ => AlbumPresence.unknown,
      };
    } catch (_) {
      return AlbumPresence.unknown;
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

  // Epoch 0 must install before the real encrypted title can be written
  // This invalid ciphertext safely falls back to Untitled Album
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
