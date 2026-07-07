import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:keepsy/data/constants.dart';
import 'package:keepsy/data/storage/storage_service.dart';
import 'api_error.dart';

class ApiClient {
  final StorageService _storage = StorageService();
  static Future<bool>? _refreshFuture;

  // Set once at startup. Fired when any album scoped request comes back
  // E_MEMBER_REVOKED : RequireMember only returns that for the *caller's* own
  // revoked membership, so this is the durable 403 fallback for the removed
  // device when the live member_revoked WS event was missed. The argument is
  // the album id parsed from the request path
  static void Function(String albumId)? onMemberRevoked;

  static final RegExp _albumIdRe = RegExp(r'/albums/([0-9a-fA-F-]{36})');

  Future<Map<String, String>> _headers() async {
    final token = await _storage.getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  Future<bool> _handleRefresh() async {
    if (_refreshFuture != null) return await _refreshFuture!;
    _refreshFuture = _doRefresh();
    final success = await _refreshFuture!;
    _refreshFuture = null;
    return success;
  }

  Future<bool> _doRefresh() async {
    final refreshToken = await _storage.getRefreshToken();
    if (refreshToken == null) return false;

    try {
      final url = Uri.parse('${AppConstants.baseURL}/auth/refresh');
      final res = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refreshToken': refreshToken}),
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final newToken = data['token'] as String?;
        final newRefresh = data['refreshToken'] as String?;
        final newExpires = data['expiresAt'] as String?;

        if (newToken != null && newRefresh != null && newExpires != null) {
          await _storage.saveAuth(newToken, newRefresh, newExpires);
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<http.Response> _sendWithRetry(
      String path, Future<http.Response> Function() requestAction) async {
    http.Response response = await requestAction();

    if (response.statusCode == 401) {
      final refreshSuccess = await _handleRefresh();
      if (refreshSuccess) {
        response = await requestAction();
      } else {
        await _storage.deleteAuth();
      }
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    final err = ApiError.fromResponse(response);
    if (err.code == 'E_MEMBER_REVOKED' && onMemberRevoked != null) {
      final m = _albumIdRe.firstMatch(path);
      if (m != null) onMemberRevoked!(m.group(1)!);
    }
    throw err;
  }

  Future<http.Response> get(String path) async {
    return _sendWithRetry(path, () async {
      final url = Uri.parse('${AppConstants.baseURL}$path');
      return await http.get(url, headers: await _headers());
    });
  }

  Future<http.Response> post(String path, {Map<String, dynamic>? body}) async {
    return _sendWithRetry(path, () async {
      final url = Uri.parse('${AppConstants.baseURL}$path');
      return await http.post(
        url,
        headers: await _headers(),
        body: body != null ? jsonEncode(body) : null,
      );
    });
  }

  Future<http.Response> put(String path, {Map<String, dynamic>? body}) async {
    return _sendWithRetry(path, () async {
      final url = Uri.parse('${AppConstants.baseURL}$path');
      return await http.put(
        url,
        headers: await _headers(),
        body: body != null ? jsonEncode(body) : null,
      );
    });
  }

  Future<http.Response> delete(String path) async {
    return _sendWithRetry(path, () async {
      final url = Uri.parse('${AppConstants.baseURL}$path');
      return await http.delete(url, headers: await _headers());
    });
  }

  Future<http.Response> patch(String path, {Map<String, dynamic>? body}) async {
    return _sendWithRetry(path, () async {
      final url = Uri.parse('${AppConstants.baseURL}$path');
      return await http.patch(
        url,
        headers: await _headers(),
        body: body != null ? jsonEncode(body) : null,
      );
    });
  }
}
