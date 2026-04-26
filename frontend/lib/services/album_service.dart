import 'dart:convert';
import '../models/album_model.dart';
import '../services/api_client.dart';

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

  Future<AlbumModel?> createAlbum(
    String name,
    String description,
    Map<String, dynamic>? widgetConfig,
  ) async {
    try {
      final response = await _client.post(
        '/albums',
        body: {
          'name': name,
          'description': description,
          'widget_config': widgetConfig ?? {},
        },
      );
      if (response.statusCode == 201) {
        return AlbumModel.fromJson(jsonDecode(response.body));
      }
      return null;
    } catch (_) {
      return null;
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

  Future<bool> addMember(String albumId, String userId) async {
    try {
      final response = await _client.post(
        '/albums/$albumId/members',
        body: {'user_id': userId},
      );
      return response.statusCode == 201;
    } catch (_) {
      return false;
    }
  }
}
