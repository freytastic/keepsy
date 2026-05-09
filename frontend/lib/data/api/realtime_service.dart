import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:keepsy/data/api/api_client.dart';
import 'package:keepsy/data/constants.dart';

class RealtimeEvent {
  final String type;
  final Map<String, dynamic> payload;
  const RealtimeEvent({required this.type, required this.payload});
}

class RealtimeService {
  final ApiClient _api;
  final _controller = StreamController<RealtimeEvent>.broadcast();
  final _connectedController = StreamController<void>.broadcast();

  WebSocketChannel? _channel;
  bool _active = false;

  RealtimeService(this._api);

  Stream<RealtimeEvent> get stream => _controller.stream;

  // Fires once per successful WS open (initial connect + every reconnect after
  // a flap). Subscribers use it to catch up on events they may have missed
  // while the socket was down. May emit spuriously if the upgrade fails right
  // after connect() returns : consumers should make catch up idempotent
  Stream<void> get connected => _connectedController.stream;

  Future<void> connect() async {
    if (_active) return;
    _active = true;
    _connectLoop();
  }

  Future<void> _connectLoop() async {
    while (_active) {
      try {
        await _connectOnce();
      } catch (_) {
        if (!_active) return;
        // Back off before retrying after a connection failure
        await Future.delayed(const Duration(seconds: 3));
      }
    }
  }

  Future<void> _connectOnce() async {
    // L5: POST to bearer-authenticated endpoint to obtain a short-lived ticket
    // The bearer token travels in the Authorization header, NEVER in the WS URL
    final resp = await _api.post('/ws-ticket');
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final ticket = data['ticket'] as String;

    _channel =
        WebSocketChannel.connect(buildWsUri(AppConstants.baseURL, ticket));
    _connectedController.add(null);

    await for (final raw in _channel!.stream) {
      if (!_active) break;
      if (raw is! String) continue;
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _controller.add(RealtimeEvent(
          type: map['type'] as String,
          payload: (map['payload'] as Map<String, dynamic>?) ?? {},
        ));
      } catch (_) {
        // Malformed frame , skip
      }
    }
  }

  // Constructs the WebSocket URI from the HTTP API base URL and a ticket
  // Exposed as a static method so tests can verify the bearer-token invariant
  // without spinning up a real connection.
  static Uri buildWsUri(String apiBase, String ticket) {
    final wsBase = apiBase
        .replaceFirst('http://', 'ws://')
        .replaceFirst('https://', 'wss://');
    return Uri.parse('$wsBase/ws?ticket=$ticket');
  }

  Future<void> disconnect() async {
    _active = false;
    await _channel?.sink.close();
    _channel = null;
  }

  void dispose() {
    disconnect();
    _controller.close();
    _connectedController.close();
  }
}
