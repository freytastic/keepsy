import 'dart:convert';

import 'package:keepsy/e2ee/prekey_api.dart';

import 'api_client.dart';
import 'api_error.dart';

// Adapter from PrekeyJsonClient (in lib/e2ee/) to ApiClient (in lib/data/)
// Translates the data layer ApiError into PrekeyApiException so e2ee/ never
// has to import package:keepsy/data/
class ApiClientPrekeyJsonClient implements PrekeyJsonClient {
  final ApiClient _api;
  ApiClientPrekeyJsonClient(this._api);

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    try {
      final resp = await _api.get(path);
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } on ApiError catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<void> postJson(String path, Map<String, dynamic> body) async {
    try {
      await _api.post(path, body: body);
    } on ApiError catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<void> putJson(String path, Map<String, dynamic> body) async {
    try {
      await _api.put(path, body: body);
    } on ApiError catch (e) {
      throw _translate(e);
    }
  }

  PrekeyApiException _translate(ApiError e) => PrekeyApiException(
        code: e.code,
        message: e.message,
        httpStatus: e.httpStatus,
      );
}
