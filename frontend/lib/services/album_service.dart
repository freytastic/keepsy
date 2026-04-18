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
}
