import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:keepsy/data/constants.dart';
import 'package:keepsy/data/storage/storage_service.dart';
import 'package:keepsy/diagnostics/trace.dart';
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

  // Reuse the trace ID when retrying after token refresh
  Map<String, String> _withTraceHeader(Map<String, String> h, String traceId) =>
      {...h, 'X-Request-ID': traceId};

  // Replace identifier-bearing path segments before logging
  static String _routeOf(String path) {
    final noQuery = path.split('?').first;
    return noQuery
        .replaceFirst(RegExp(r'^/invite/[^/]+'), '/invite/{code}')
        .replaceFirst(
            RegExp(r'^/users/by-handle/[^/]+'), '/users/by-handle/{handle}')
        .replaceAll(
            RegExp(r'/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}'
                r'-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'),
            '/{id}')
        .replaceAll(RegExp(r'/[A-Za-z0-9_-]{22,}'), '/{token}');
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
      final url = Uri.parse('${AppConstants.baseURL}/auth/otp/refresh');
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

  Future<http.Response> _sendWithRetry(String method, String path,
      String traceId, Future<http.Response> Function() requestAction) async {
    final span = Trace.start('api.request', traceId: traceId, fields: {
      'method': method,
      'route': _routeOf(path),
    });
    try {
      var response = await requestAction();

      var refreshed = false;
      if (response.statusCode == 401) {
        final refreshSuccess = await _handleRefresh();
        if (refreshSuccess) {
          refreshed = true;
          response = await requestAction();
        } else {
          await _storage.deleteAuth();
        }
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        span.end(fields: {
          'status': response.statusCode,
          'bytes': response.bodyBytes.length,
          if (refreshed) 'refreshed': true,
        });
        return response;
      }
      span.fail('http_${response.statusCode}', fields: {
        'status': response.statusCode,
        'bytes': response.bodyBytes.length,
        if (refreshed) 'refreshed': true,
      });
      final err = ApiError.fromResponse(response);
      if (err.code == 'E_MEMBER_REVOKED' && onMemberRevoked != null) {
        final m = _albumIdRe.firstMatch(path);
        if (m != null) onMemberRevoked!(m.group(1)!);
      }
      throw err;
    } catch (error) {
      span.fail(Trace.reasonOf(error));
      rethrow;
    }
  }

  Future<http.Response> get(String path) async {
    final tid = Trace.currentId ?? Trace.newTraceId();
    return _sendWithRetry('GET', path, tid, () async {
      final url = Uri.parse('${AppConstants.baseURL}$path');
      return await http.get(url,
          headers: _withTraceHeader(await _headers(), tid));
    });
  }

  Future<http.Response> post(String path, {Map<String, dynamic>? body}) async {
    final tid = Trace.currentId ?? Trace.newTraceId();
    return _sendWithRetry('POST', path, tid, () async {
      final url = Uri.parse('${AppConstants.baseURL}$path');
      return await http.post(
        url,
        headers: _withTraceHeader(await _headers(), tid),
        body: body != null ? jsonEncode(body) : null,
      );
    });
  }

  Future<http.Response> put(String path, {Map<String, dynamic>? body}) async {
    final tid = Trace.currentId ?? Trace.newTraceId();
    return _sendWithRetry('PUT', path, tid, () async {
      final url = Uri.parse('${AppConstants.baseURL}$path');
      return await http.put(
        url,
        headers: _withTraceHeader(await _headers(), tid),
        body: body != null ? jsonEncode(body) : null,
      );
    });
  }

  Future<http.Response> delete(String path) async {
    final tid = Trace.currentId ?? Trace.newTraceId();
    return _sendWithRetry('DELETE', path, tid, () async {
      final url = Uri.parse('${AppConstants.baseURL}$path');
      return await http.delete(url,
          headers: _withTraceHeader(await _headers(), tid));
    });
  }

  Future<http.Response> patch(String path, {Map<String, dynamic>? body}) async {
    final tid = Trace.currentId ?? Trace.newTraceId();
    return _sendWithRetry('PATCH', path, tid, () async {
      final url = Uri.parse('${AppConstants.baseURL}$path');
      return await http.patch(
        url,
        headers: _withTraceHeader(await _headers(), tid),
        body: body != null ? jsonEncode(body) : null,
      );
    });
  }
}
