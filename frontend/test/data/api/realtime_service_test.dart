import 'package:test/test.dart';
import 'package:keepsy/data/api/api_client.dart';
import 'package:keepsy/data/api/realtime_service.dart';

void main() {
  group('RealtimeService.connected', () {
    // Surface only test : the controller is broadcast (multiple subscribers
    // tolerated) and dispose() closes it. The actual emit on connect is
    // exercised end to end by manual verification + the connect loop in prod
    test('exposes a broadcast stream', () {
      final svc = RealtimeService(ApiClient());
      expect(svc.connected.isBroadcast, isTrue);
      svc.dispose();
    });
  });

  group('RealtimeService.buildWsUri', () {
    test('converts http to ws scheme', () {
      final uri =
          RealtimeService.buildWsUri('http://localhost:8080/api/v1', 'abc');
      expect(uri.scheme, equals('ws'));
    });

    test('converts https to wss scheme', () {
      final uri =
          RealtimeService.buildWsUri('https://api.keepsy.app/api/v1', 'abc');
      expect(uri.scheme, equals('wss'));
    });

    test('ticket appears as query parameter', () {
      final uri = RealtimeService.buildWsUri(
          'http://localhost:8080/api/v1', 'my-ticket-42');
      expect(uri.queryParameters['ticket'], equals('my-ticket-42'));
    });

    // L5 bearer token guard: the WS URL must never carry Authorization or token=
    test('URL does not contain Authorization header value or token= param', () {
      final uri = RealtimeService.buildWsUri(
          'http://localhost:8080/api/v1', 'my-ticket');
      final urlStr = uri.toString();
      expect(urlStr, isNot(contains('Authorization')));
      expect(urlStr, isNot(contains('token=')));
    });

    test('path ends with /ws', () {
      final uri =
          RealtimeService.buildWsUri('http://localhost:8080/api/v1', 'x');
      expect(uri.path, endsWith('/ws'));
    });
  });
}
