import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:keepsy/data/constants.dart';
import 'package:keepsy/data/storage/storage_service.dart';

// Distinguishes authoritative rejection from a transient refresh failure
enum RefreshOutcome {
  renewed,
  // Server rejected the session, so its credentials are unusable
  rejected,
  // Failure did not prove the session invalid, so retry later
  unavailable,
}

typedef RefreshPoster = Future<http.Response> Function(String refreshToken);

// Renew before expiry because an expired session cannot be refreshed
const Duration kRenewalWindow = Duration(days: 7);

class SessionRefresher {
  final StorageService _storage = StorageService();
  final RefreshPoster _post;

  SessionRefresher({RefreshPoster? post}) : _post = post ?? _defaultPost;

  static Future<http.Response> _defaultPost(String refreshToken) => http.post(
        Uri.parse('${AppConstants.baseURL}/auth/otp/refresh'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refreshToken': refreshToken}),
      );

  // True once the session enters the proactive renewal window
  static bool shouldRenew({
    required DateTime? expiresAt,
    required DateTime now,
  }) {
    if (expiresAt == null) return false;
    return expiresAt.isBefore(now.add(kRenewalWindow));
  }

  // No-op while the stored session has enough time remaining
  Future<RefreshOutcome?> renewIfDue({DateTime Function()? clock}) async {
    final expiry = await _storage.getExpiry();
    final now = (clock ?? DateTime.now)();
    if (!shouldRenew(expiresAt: expiry, now: now)) return null;
    return refresh();
  }

  Future<RefreshOutcome> refresh() async {
    final refreshToken = await _storage.getRefreshToken();
    if (refreshToken == null) return RefreshOutcome.rejected;

    final http.Response res;
    try {
      res = await _post(refreshToken);
    } catch (_) {
      return RefreshOutcome.unavailable;
    }

    // Only 401 authoritatively rejects this session
    if (res.statusCode == 401) return RefreshOutcome.rejected;
    if (res.statusCode != 200) return RefreshOutcome.unavailable;

    try {
      final data = jsonDecode(res.body);
      final token = data['token'] as String?;
      final refresh = data['refreshToken'] as String?;
      final expires = data['expiresAt'] as String?;
      if (token == null || refresh == null || expires == null) {
        return RefreshOutcome.unavailable;
      }
      await _storage.saveAuth(token, refresh, expires);
      return RefreshOutcome.renewed;
    } catch (_) {
      // A 200 we cannot parse is a server problem, not a dead session
      return RefreshOutcome.unavailable;
    }
  }
}
