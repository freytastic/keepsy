import 'package:shared_preferences/shared_preferences.dart';

/// handles read write delete of JWT credentials via SharedPreferences.
class StorageService {
  static const _keyToken = 'auth_token';
  static const _keyRefreshToken = 'auth_refresh_token';
  static const _keyExpiry = 'auth_expires_at';

  // singleton
  static final StorageService _instance = StorageService._();
  factory StorageService() => _instance;
  StorageService._();

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _sp async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  // write
  Future<void> saveAuth(String token, String refreshToken, String expiresAt) async {
    final sp = await _sp;
    await sp.setString(_keyToken, token);
    await sp.setString(_keyRefreshToken, refreshToken);
    await sp.setString(_keyExpiry, expiresAt);
  }

  // read
  Future<String?> getToken() async {
    final sp = await _sp;
    return sp.getString(_keyToken);
  }

  Future<String?> getRefreshToken() async {
    final sp = await _sp;
    return sp.getString(_keyRefreshToken);
  }

  Future<DateTime?> getExpiry() async {
    final sp = await _sp;
    final raw = sp.getString(_keyExpiry);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  // validate
  Future<bool> isValid() async {
    final token = await getToken();
    if (token == null || token.isEmpty) return false;

    final expiry = await getExpiry();
    if (expiry == null) return false;

    return DateTime.now().isBefore(expiry);
  }

  // delete (logout)
  Future<void> deleteAuth() async {
    final sp = await _sp;
    await sp.remove(_keyToken);
    await sp.remove(_keyRefreshToken);
    await sp.remove(_keyExpiry);
  }
}
