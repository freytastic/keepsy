import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:keepsy/data/api/api_error.dart';
import 'package:keepsy/data/constants.dart';
import 'package:keepsy/data/storage/storage_service.dart';

// Sign in reached an account whose deletion is still being finished
class AccountDeletingException implements Exception {
  const AccountDeletingException();
}

class AuthService {
  final StorageService _storage = StorageService();

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

  // Crypto bootstrap remains asynchronous after credentials are stored
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
      if (ApiError.tryParse(response)?.code == 'E_ACCOUNT_DELETING') {
        throw const AccountDeletingException();
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
