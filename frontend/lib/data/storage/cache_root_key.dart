import 'dart:typed_data';

import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/secure_store/key_handle.dart';
import 'package:keepsy/secure_store/secure_key_store.dart';

const String kCacheRootKeyLabel = 'cache_root_key';
const int kCacheRootKeyLen = 32;

// Device bound 256 bit key sealing the L2 media cache. Generated once at first
// launch, persisted in the keystore, extracted
// into RAM once per process. Independent of any album MK : epoch rotation never
// invalidates the cache. The returned copy is the only plaintext outside the
// keystore boundary ,caller owns its lifetime
Future<Uint8List> loadOrCreateCacheRootKey(SecureKeyStore store) async {
  final existing = await store.list(labelPrefix: kCacheRootKeyLabel);
  final KeyHandle handle = existing.isNotEmpty
      ? existing.first
      : await store.put(kCacheRootKeyLabel, Csprng.bytes(kCacheRootKeyLen));
  return store.use(handle, (raw) async => Uint8List.fromList(raw));
}

// Drop every cache_root_key handle so any remnant .kec becomes permanently
// undecryptable. Not used by logout (the key is device bound and kept) : this
// is the primitive for a full account reset / device wipe
Future<void> deleteCacheRootKey(SecureKeyStore store) async {
  for (final h in await store.list(labelPrefix: kCacheRootKeyLabel)) {
    await store.delete(h);
  }
}
