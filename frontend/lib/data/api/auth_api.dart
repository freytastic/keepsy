import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:keepsy/data/constants.dart';
import 'package:keepsy/data/storage/storage_service.dart';
import 'package:keepsy/e2ee/identity.dart';

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

  // verify OTP & persist credentials, then block on E2EE bootstrap (D4)
  // Returns 'true' once token is saved AND IdentityService.bootstrap() has
  // either run or confirmed the user is already bootstrapped. Bootstrap
  // failure : returns 'false' so the UI can surface "encryption setup failed"
  // instead of pretending login succeeded

  // BootstrapAccountConflictException is rethrown verbatim : it signals an
  // unrecoverable mismatch (server has different IK than what this device
  // can produce) and the UI must show a distinct message rather than hint
  // at "wrong OTP"
  Future<bool> verifyOtp(
      String email, String code, IdentityService identity) async {
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
          // D4 : hard block login completion until the E2EE identity is
          // published. bootstrap() is idempotent + resumable, so retried
          // logins after a partial failure pick up where the last attempt
          // stopped instead of wedging on E_IDENTITY_ALREADY_SET
          if (!await identity.isBootstrapped()) {
            await identity.bootstrap();
          }
          return true;
        }
      }
      return false;
    } on BootstrapAccountConflictException {
      rethrow;
    } catch (_) {
      return false;
    }
  }

  // logout
  Future<void> logout() async {
    await _storage.deleteAuth();
  }
}
