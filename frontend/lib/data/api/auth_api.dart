import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:keepsy/data/constants.dart';
import 'package:keepsy/data/storage/storage_service.dart';

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

  // verify OTP and persist credentials. Returns 'true' once token is saved
  // E2EE bootstrap is NOT done here anymore (was D4 hard block) : the caller
  // fires identity.bootstrap() unawaited after navigation so the user gets
  // an instant home screen instead of staring at a spinner during the
  // keystore heavy bootstrap. cryptoReady gates any subsequent crypto action
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
          // M8 privacy : server stores email_hmac, not plaintext, so the
          // client persists its own email for profile screen display
          await _storage.saveEmail(email);
          return true;
        }
      }
      return false;
    } catch (e) {
      rethrow;
    }
  }

  // logout
  Future<void> logout() async {
    await _storage.deleteAuth();
  }
}
