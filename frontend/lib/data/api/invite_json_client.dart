import 'dart:convert';

import 'package:keepsy/e2ee/invite_api.dart';

import 'api_client.dart';

// Adapter from InviteJsonClient (lib/e2ee/) to ApiClient (lib/data/). HttpInviteApi
// itself is in lib/e2ee/invite_api.dart so e2ee/ never imports the data layer
// Non-2xx ApiErrors propagate (caller maps 409/404 to UI copy)
class ApiClientInviteJsonClient implements InviteJsonClient {
  final ApiClient _api;
  ApiClientInviteJsonClient(this._api);

  @override
  Future<Map<String, dynamic>> postJsonForResult(
      String path, Map<String, dynamic> body) async {
    final resp = await _api.post(path, body: body);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  @override
  Future<void> postJson(String path, Map<String, dynamic> body) async {
    await _api.post(path, body: body);
  }
}
