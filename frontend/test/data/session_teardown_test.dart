import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:keepsy/data/api/auth_api.dart';
import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/data/session_teardown.dart';
import 'package:keepsy/data/storage/cache_root_key.dart';
import 'package:keepsy/data/storage/media_cache_key.dart';
import 'package:keepsy/data/storage/media_cache_manager.dart';
import 'package:keepsy/data/storage/media_plaintext_cache.dart';
import 'package:keepsy/data/storage/media_sealed_cache.dart';
import 'package:keepsy/data/storage/name_cache.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/media_record.dart';

import '../secure_store/mock_secure_key_store.dart';

Uint8List _albumIdBytes() => Uint8List.fromList(List<int>.filled(16, 0xA1));
Uint8List _mk() => Uint8List.fromList(List<int>.filled(32, 0x42));

class _DeadApi implements MediaApiInterface {
  @override
  Future<List<MediaRecord>> listMedia(String albumId) async =>
      throw StateError('api must not be called during logout');
  @override
  Future<String> requestDownloadURL(String a, String m,
          {String asset = 'file'}) async =>
      throw StateError('api must not be called during logout');
  @override
  Future<Uint8List> downloadCiphertext(String url) async =>
      throw StateError('api must not be called during logout');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // credentials now live in secure storage : logout deletes them there
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
      'performLogout clears auth + wipes media cache but KEEPS the '
      'device-bound cache_root_key and album keys', () async {
    SharedPreferences.setMockInitialValues({
      'auth_token': 'tok',
      'auth_refresh_token': 'r',
    });
    final tmp = Directory.systemTemp.createTempSync('logout_');
    final store = MockSecureKeyStore();
    await store.initialize();
    final aks = AlbumKeyStore(store);
    await aks.initialize();
    await aks.installVerified(
        albumId: _albumIdBytes(), epoch: 0, mk: _mk(), backfill: false);

    final cacheKey = await loadOrCreateCacheRootKey(store);
    final l2 = await MediaSealedCache.open(
        rootDir: tmp, cacheRootKey: cacheKey, budgetBytes: 1 << 20);
    final l1 = MediaPlaintextCache();
    final mgr = MediaCacheManager(
        plaintext: l1, ciphertext: l2, api: _DeadApi(), aks: aks);

    final k = MediaCacheKey(
        albumId: 'A', mediaId: 'm1', epochTag: 0, asset: CacheAsset.file);
    final pt = Uint8List.fromList(List.generate(64, (i) => i));
    l1.put(k, pt);
    await l2.writeBlob(k, pt);

    final nameCache = await NameCache.open(
        file: File('${tmp.path}/names.kec'), cacheRootKey: cacheKey);
    nameCache.put(NameCache.albumKey('A'), 'Secret Album', 'ct');
    await nameCache.flush();

    await performLogout(
        auth: AuthService(), mediaCache: mgr, nameCache: nameCache);

    // name cache is album content : wiped on logout like the media cache
    expect(nameCache.get(NameCache.albumKey('A'), 'ct'), isNull);
    expect(File('${tmp.path}/names.kec').existsSync(), isFalse);

    // cache_root_key is device bound (like album MKs) : it MUST survive logout
    // Deleting it stranded blobs sealed under the in RAM key after a same process
    // re login, forcing a full re download on the next cold start
    expect(await store.list(labelPrefix: kCacheRootKeyLabel), isNotEmpty);
    expect(await l2.readBlob(k), isNull);
    expect(l1.get(k), isNull);
    // album MK survives : logout must not cost the user album access
    expect(await aks.presentEpochs(_albumIdBytes()), contains(0));
    final sp = await SharedPreferences.getInstance();
    expect(sp.getString('auth_token'), isNull);

    await l2.close();
    tmp.deleteSync(recursive: true);
  });

  test('performLogout disconnects realtime', () async {
    SharedPreferences.setMockInitialValues({'auth_token': 'tok'});
    final tmp = Directory.systemTemp.createTempSync('logout_rt_');
    final store = MockSecureKeyStore();
    await store.initialize();
    final aks = AlbumKeyStore(store);
    await aks.initialize();
    final cacheKey = await loadOrCreateCacheRootKey(store);
    final l2 = await MediaSealedCache.open(
        rootDir: tmp, cacheRootKey: cacheKey, budgetBytes: 1 << 20);
    final mgr = MediaCacheManager(
        plaintext: MediaPlaintextCache(),
        ciphertext: l2,
        api: _DeadApi(),
        aks: aks);
    final nameCache = await NameCache.open(
        file: File('${tmp.path}/names.kec'), cacheRootKey: cacheKey);

    var disconnected = false;
    await performLogout(
      auth: AuthService(),
      mediaCache: mgr,
      nameCache: nameCache,
      disconnectRealtime: () async {
        disconnected = true;
      },
    );

    expect(disconnected, isTrue);

    await l2.close();
    tmp.deleteSync(recursive: true);
  });
}
