import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import '../services/storage_service.dart';

// attaches jwt to requests and refreshes on 401 and retires request
class ApiClient {
  // global navigator key ─ set this in MaterialApp 
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  final StorageService _storage = StorageService();
  static Future<bool>? _refreshFuture;

  // helpers 
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
      final url = Uri.parse('${K.baseURL}/auth/refresh');
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
      Future<http.Response> Function() requestAction) async {
    http.Response response = await requestAction();

    // If unauthorized, attempt to pause, refresh the token, and retry
    if (response.statusCode == 401) {
      final refreshSuccess = await _handleRefresh();

      if (refreshSuccess) {
        // Retry the request. When requestAction runs, it will call _headers() 
        // again and smoothly pick up the new token!
        response = await requestAction();
      } else {
        // Refresh failed (or expired), force logout
        await _storage.deleteAuth();
        navigatorKey.currentState?.pushNamedAndRemoveUntil(
          '/login',
          (_) => false,
        );
      }
    }
    return response;
  }

  // public API 
  Future<http.Response> get(String path) async {
    return _sendWithRetry(() async {
      final url = Uri.parse('${K.baseURL}$path');
      return await http.get(url, headers: await _headers());
    });
  }

  Future<http.Response> post(String path, {Map<String, dynamic>? body}) async {
    return _sendWithRetry(() async {
      final url = Uri.parse('${K.baseURL}$path');
      return await http.post(
        url,
        headers: await _headers(),
        body: body != null ? jsonEncode(body) : null,
      );
    });
  }

  Future<http.Response> put(String path, {Map<String, dynamic>? body}) async {
    return _sendWithRetry(() async {
      final url = Uri.parse('${K.baseURL}$path');
      return await http.put(
        url,
        headers: await _headers(),
        body: body != null ? jsonEncode(body) : null,
      );
    });
  }

  Future<http.Response> delete(String path) async {
    return _sendWithRetry(() async {
      final url = Uri.parse('${K.baseURL}$path');
      return await http.delete(url, headers: await _headers());
    });
  }
}
