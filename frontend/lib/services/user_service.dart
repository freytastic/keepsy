import 'dart:convert';
import '../services/api_client.dart';

class UserService {
  final ApiClient _client = ApiClient();

  Future<Map<String, dynamic>?> getMe() async {
    try {
      final response = await _client.get('/users/me');
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> updateMe(Map<String, dynamic> data) async {
    try {
      final response = await _client.patch('/users/me', body: data);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
