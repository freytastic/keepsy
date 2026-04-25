import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import '../services/storage_service.dart';

class AuthService {
  final StorageService _storage = StorageService();

  // request OTP
  Future<bool> requestOtp(String email) async {
    try {
      final url = Uri.parse('${AppConstants.baseURL}/auth/otp/request');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // verify OTP & persist credentials 
  /// Returns `true` on success (token saved), `false` otherwise.
  Future<bool> verifyOtp(String email, String code) async {
    try {
      final url = Uri.parse('${AppConstants.baseURL}/auth/otp/verify');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'otp': code}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final token = data['token'] as String?;
        final refreshToken = data['refreshToken'] as String?;
        final expiresAt = data['expiresAt'] as String?;

        if (token != null && refreshToken != null && expiresAt != null) {
          await _storage.saveAuth(token, refreshToken, expiresAt);
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // logout
  Future<void> logout() async {
    await _storage.deleteAuth();
  }
}