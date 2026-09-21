import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:keepsy/data/api/session_refresher.dart';
import 'package:keepsy/data/storage/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storage;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.saveAuth('old', 'old', '2030-01-01T00:00:00Z');
  });

  SessionRefresher refresherReturning(Future<http.Response> Function() post) =>
      SessionRefresher(post: (_) => post());

  test('a renewed session replaces the stored credentials', () async {
    final outcome = await refresherReturning(() async => http.Response(
          jsonEncode({
            'token': 'fresh',
            'refreshToken': 'fresh',
            'expiresAt': '2031-01-01T00:00:00Z',
          }),
          200,
        )).refresh();

    expect(outcome, RefreshOutcome.renewed);
    expect(await storage.getToken(), 'fresh');
  });

  // A dropped connection must not destroy a valid credential
  test('a network failure leaves the credentials alone', () async {
    final outcome = await refresherReturning(
      () async => throw const SocketException('no route to host'),
    ).refresh();

    expect(outcome, RefreshOutcome.unavailable);
    expect(await storage.getToken(), 'old');
  });

  test('a server error leaves the credentials alone', () async {
    final outcome =
        await refresherReturning(() async => http.Response('', 503)).refresh();

    expect(outcome, RefreshOutcome.unavailable);
    expect(await storage.getToken(), 'old');
  });

  test('a malformed success body is treated as unavailable', () async {
    final outcome = await refresherReturning(
      () async => http.Response(jsonEncode({'token': 'only'}), 200),
    ).refresh();

    expect(outcome, RefreshOutcome.unavailable);
    expect(await storage.getToken(), 'old');
  });

  // Only authoritative rejection may end the session
  test('an unauthorized response rejects the session', () async {
    final outcome =
        await refresherReturning(() async => http.Response('', 401)).refresh();

    expect(outcome, RefreshOutcome.rejected);
  });

  // A 403 is not the refresh endpoint's dead-session signal
  test('a forbidden response leaves the credentials alone', () async {
    final outcome =
        await refresherReturning(() async => http.Response('', 403)).refresh();

    expect(outcome, RefreshOutcome.unavailable);
    expect(await storage.getToken(), 'old');
  });

  test('a missing refresh token rejects without a request', () async {
    await storage.deleteAuth();
    var called = false;
    final outcome = await SessionRefresher(post: (_) async {
      called = true;
      return http.Response('', 200);
    }).refresh();

    expect(outcome, RefreshOutcome.rejected);
    expect(called, isFalse);
  });

  _proactive();
}

void _proactive() {
  group('refreshing before expiry', () {
    // Proactive renewal keeps an active sliding session alive
    test('refreshes when the expiry is inside the renewal window', () {
      expect(
        SessionRefresher.shouldRenew(
          expiresAt: DateTime(2030, 1, 10),
          now: DateTime(2030, 1, 5),
        ),
        isTrue,
      );
    });

    test('leaves a session with plenty of life alone', () {
      expect(
        SessionRefresher.shouldRenew(
          expiresAt: DateTime(2030, 2, 10),
          now: DateTime(2030, 1, 5),
        ),
        isFalse,
      );
    });

    // This path is reachable on resume, not cold launch
    test('still renews one that has only just lapsed', () {
      expect(
        SessionRefresher.shouldRenew(
          expiresAt: DateTime(2030, 1, 4),
          now: DateTime(2030, 1, 5),
        ),
        isTrue,
      );
    });

    test('does nothing without an expiry', () {
      expect(SessionRefresher.shouldRenew(expiresAt: null, now: DateTime(2030)),
          isFalse);
    });
  });
}
