import 'package:shared_preferences/shared_preferences.dart';

/// handles read write delete of JWT credentials via SharedPreferences.
class StorageService {
  static const _keyToken = 'auth_token';
  static const _keyRefreshToken = 'auth_refresh_token';
  static const _keyExpiry = 'auth_expires_at';
  // Server stores users.email_hmac, never the plaintext, so the client owns
  // its own email cache for display in the profile screen
  static const _keyEmail = 'auth_email';
  // M7 : display name lives encrypted per album in album_members.name_ct
  // The user's own typed name is cached locally for the profile screen :
  // pushing to each album's name_ct slot is wired in Phase 5
  static const _keyName = 'auth_name';

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
  Future<void> saveAuth(
      String token, String refreshToken, String expiresAt) async {
    final sp = await _sp;
    await sp.setString(_keyToken, token);
    await sp.setString(_keyRefreshToken, refreshToken);
    await sp.setString(_keyExpiry, expiresAt);
  }

  Future<void> saveEmail(String email) async {
    final sp = await _sp;
    await sp.setString(_keyEmail, email);
  }

  Future<String?> getEmail() async {
    final sp = await _sp;
    return sp.getString(_keyEmail);
  }

  Future<void> saveName(String name) async {
    final sp = await _sp;
    await sp.setString(_keyName, name);
  }

  Future<String?> getName() async {
    final sp = await _sp;
    return sp.getString(_keyName);
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
    await sp.remove(_keyEmail);
    await sp.remove(_keyName);
  }
}
