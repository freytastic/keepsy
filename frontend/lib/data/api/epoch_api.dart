import 'dart:convert';

import 'package:keepsy/e2ee/epoch_api.dart';

import 'api_client.dart';
import 'api_error.dart';

// Adapter from EpochJsonClient (in lib/e2ee/) to ApiClient (in lib/data/)
// Maps 404 to a null body so HttpEpochApi can surface
// EpochWrapNotFoundException + treat \"album has no epoch yet\" as null
// HttpEpochApi itself lives in lib/e2ee/epoch_api.dart (mirrors HttpPrekeyApi)

class ApiClientEpochJsonClient implements EpochJsonClient {
  final ApiClient _api;
  ApiClientEpochJsonClient(this._api);

  @override
  Future<Map<String, dynamic>?> getJsonOrNotFound(String path) async {
    try {
      final resp = await _api.get(path);
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } on ApiError catch (e) {
      if (e.httpStatus == 404) return null;
      rethrow;
    }
  }
}
