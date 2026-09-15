import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Keeps credentials in secure storage and non-secret display values in prefs
class StorageService {
  static const _keyToken = 'auth_token';
  static const _keyRefreshToken = 'auth_refresh_token';
  static const _keyExpiry = 'auth_expires_at';
  // Server stores users.email_hmac, never the plaintext, so the client owns
  // its own email cache for display in the profile screen
  static const _keyEmail = 'auth_email';
  // The typed profile name is a local cache for per-album encrypted names
  static const _keyName = 'auth_name';
  // Lets sealed uploads be matched to their account before the network answers
  static const _keyUserId = 'auth_user_id';

  static final StorageService _instance = StorageService._();
  factory StorageService() => _instance;
  StorageService._();

  // const : each call resolves the current platform (mockable in tests via
  // FlutterSecureStorage.setMockInitialValues)
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _sp async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  Future<void> saveAuth(
      String token, String refreshToken, String expiresAt) async {
    await _secure.write(key: _keyToken, value: token);
    await _secure.write(key: _keyRefreshToken, value: refreshToken);
    await _secure.write(key: _keyExpiry, value: expiresAt);
    // scrub any plaintext credential left behind by an install upgraded from
    // the old prefs based build : the first fresh login must not leave it at rest
    final sp = await _sp;
    await sp.remove(_keyToken);
    await sp.remove(_keyRefreshToken);
    await sp.remove(_keyExpiry);
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

  Future<void> saveUserId(String id) async {
    final sp = await _sp;
    await sp.setString(_keyUserId, id);
  }

  Future<String?> getUserId() async {
    final sp = await _sp;
    return sp.getString(_keyUserId);
  }

  Future<String?> getToken() => _secure.read(key: _keyToken);

  Future<String?> getRefreshToken() => _secure.read(key: _keyRefreshToken);

  Future<DateTime?> getExpiry() async {
    final raw = await _secure.read(key: _keyExpiry);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  Future<bool> isValid() async {
    final token = await getToken();
    if (token == null || token.isEmpty) return false;

    final expiry = await getExpiry();
    if (expiry == null) return false;

    return DateTime.now().isBefore(expiry);
  }

  Future<void> deleteAuth() async {
    await _secure.delete(key: _keyToken);
    await _secure.delete(key: _keyRefreshToken);
    await _secure.delete(key: _keyExpiry);
    final sp = await _sp;
    // legacy cleanup : older builds kept the tokens in SharedPreferences
    await sp.remove(_keyToken);
    await sp.remove(_keyRefreshToken);
    await sp.remove(_keyExpiry);
    await sp.remove(_keyEmail);
    await sp.remove(_keyName);
    await sp.remove(_keyUserId);
  }
}
