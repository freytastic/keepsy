import 'dart:convert';
import 'package:keepsy/data/api/api_client.dart';

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
}
