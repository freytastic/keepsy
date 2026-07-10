import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:keepsy/data/storage/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('saveAuth stores credentials in secure storage, NOT SharedPreferences',
      () async {
    final s = StorageService();
    await s.saveAuth('tok', 'refresh', '2030-01-01T00:00:00Z');

    // readable through the service
    expect(await s.getToken(), 'tok');
    expect(await s.getRefreshToken(), 'refresh');
    expect((await s.getExpiry())?.toUtc(), DateTime.utc(2030, 1, 1));

    // credentials MUST NOT sit in plaintext SharedPreferences
    final sp = await SharedPreferences.getInstance();
    expect(sp.getString('auth_token'), isNull);
    expect(sp.getString('auth_refresh_token'), isNull);
    expect(sp.getString('auth_expires_at'), isNull);

    // they DO sit in secure storage
    const secure = FlutterSecureStorage();
    expect(await secure.read(key: 'auth_token'), 'tok');
    expect(await secure.read(key: 'auth_refresh_token'), 'refresh');
  });

  test('saveAuth purges any legacy plaintext token left in SharedPreferences',
      () async {
    // an install upgraded from the old prefs-based build carries a plaintext
    // token. The first fresh login must scrub it, not just overwrite secure
    SharedPreferences.setMockInitialValues({
      'auth_token': 'legacy-plaintext',
      'auth_refresh_token': 'legacy-refresh',
    });
    final s = StorageService();
    await s.saveAuth('new', 'newr', '2030-01-01T00:00:00Z');

    final sp = await SharedPreferences.getInstance();
    expect(sp.getString('auth_token'), isNull);
    expect(sp.getString('auth_refresh_token'), isNull);
  });

  test('deleteAuth wipes credentials from secure storage', () async {
    final s = StorageService();
    await s.saveAuth('tok', 'refresh', '2030-01-01T00:00:00Z');
    await s.saveEmail('a@b.c');

    await s.deleteAuth();

    expect(await s.getToken(), isNull);
    expect(await s.getRefreshToken(), isNull);
    expect(await s.getEmail(), isNull);
    const secure = FlutterSecureStorage();
    expect(await secure.read(key: 'auth_token'), isNull);
  });

  test('isValid is false with no token, true with an unexpired one', () async {
    final s = StorageService();
    expect(await s.isValid(), isFalse);

    await s.saveAuth('tok', 'refresh',
        DateTime.now().add(const Duration(hours: 1)).toIso8601String());
    expect(await s.isValid(), isTrue);

    await s.saveAuth('tok', 'refresh',
        DateTime.now().subtract(const Duration(hours: 1)).toIso8601String());
    expect(await s.isValid(), isFalse);
  });
}
