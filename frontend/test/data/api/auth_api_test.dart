import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:keepsy/data/api/auth_api.dart';
import 'package:keepsy/data/storage/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const userId = '11111111-1111-4111-8111-111111111111';

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  http.Client okClient() => MockClient((_) async => http.Response(
        jsonEncode({
          'user_id': userId,
          'token': 'tok',
          'refreshToken': 'tok',
          'expiresAt': '2030-01-01T00:00:00Z',
        }),
        200,
      ));

  // Verification must not bypass the vault-owner check by persisting early
  test('verifyOtp returns the pending session without persisting it', () async {
    final auth = AuthService(client: okClient());

    final pending = await auth.verifyOtp('a@example.com', '123456');

    expect(pending, isNotNull);
    expect(pending!.userId, userId);
    expect(pending.token, 'tok');

    final storage = StorageService();
    expect(await storage.getToken(), isNull,
        reason: 'credentials must not be written before the owner check');
    expect(await storage.getUserId(), isNull);
  });

  test('commit persists the session and the account it belongs to', () async {
    final auth = AuthService(client: okClient());
    final pending = await auth.verifyOtp('a@example.com', '123456');

    await auth.commit(pending!, email: 'a@example.com');

    final storage = StorageService();
    expect(await storage.getToken(), 'tok');
    expect(await storage.getUserId(), userId);
    expect(await storage.getEmail(), 'a@example.com');
  });

  test('verifyOtp returns null when the code is rejected', () async {
    final auth = AuthService(
      client: MockClient((_) async => http.Response('{}', 401)),
    );
    expect(await auth.verifyOtp('a@example.com', '000000'), isNull);
  });
}
