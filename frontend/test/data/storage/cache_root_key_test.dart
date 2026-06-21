import 'package:flutter_test/flutter_test.dart';

import 'package:keepsy/data/storage/cache_root_key.dart';

import '../../secure_store/mock_secure_key_store.dart';

void main() {
  late MockSecureKeyStore store;

  setUp(() async {
    store = MockSecureKeyStore();
    await store.initialize();
  });

  test('generates a 32-byte key on first call', () async {
    final k = await loadOrCreateCacheRootKey(store);
    expect(k.length, kCacheRootKeyLen);
  });

  test('returns the same key on a second call', () async {
    final first = await loadOrCreateCacheRootKey(store);
    final second = await loadOrCreateCacheRootKey(store);
    expect(second, equals(first));
  });

  test('persists exactly one handle under the cache_root_key label', () async {
    await loadOrCreateCacheRootKey(store);
    await loadOrCreateCacheRootKey(store);
    final handles = await store.list(labelPrefix: kCacheRootKeyLabel);
    expect(handles.length, 1);
  });

  test('deleteCacheRootKey removes the handle; next load mints a fresh key',
      () async {
    final first = await loadOrCreateCacheRootKey(store);
    await deleteCacheRootKey(store);
    expect(await store.list(labelPrefix: kCacheRootKeyLabel), isEmpty);
    final second = await loadOrCreateCacheRootKey(store);
    expect(second, isNot(equals(first)));
  });
}
