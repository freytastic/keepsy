import 'dart:convert';
import '../services/api_client.dart';

class MediaService {
  final ApiClient _client = ApiClient();

  Future<List<dynamic>> listMedia(String albumId) async {
    try {
      final response = await _client.get('/albums/$albumId/media');
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  Future<Map<String, dynamic>?> requestUploadURL({
    required String albumId,
    required String fileName,
    required String contentType,
    required int fileSize,
    required String mediaType, // "photo" or "video"
  }) async {
    try {
      final response = await _client.post(
        '/albums/$albumId/media/upload-url',
        body: {
          'file_name': fileName,
          'content_type': contentType,
          'file_size': fileSize,
          'media_type': mediaType,
        },
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> confirmUpload(Map<String, dynamic> mediaData) async {
    try {
      final response = await _client.post(
        '/albums/${mediaData['album_id']}/media/confirm',
        body: mediaData,
      );
      return response.statusCode == 201;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteMedia(String albumId, String mediaId) async {
    try {
      final response = await _client.delete('/albums/$albumId/media/$mediaId');
      return response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }
}
