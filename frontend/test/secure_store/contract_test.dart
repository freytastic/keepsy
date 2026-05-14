import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/secure_store/key_store_exceptions.dart';
import 'package:keepsy/secure_store/secure_key_store.dart';

import 'mock_secure_key_store.dart';

typedef StoreFactory = SecureKeyStore Function();

// Reused by integration tests against the real Android/iOS impls
void runContractTests(String name, StoreFactory factory) {
  group('$name contract', () {
    late SecureKeyStore store;

    setUp(() async {
      store = factory();
      await store.initialize();
    });

    test('put then use round-trips bytes', () async {
      final pt = Uint8List.fromList(List.generate(32, (i) => i));
      final h = await store.put('test.k', pt);
      final got = await store.use(h, (b) async => Uint8List.fromList(b));
      expect(got, equals(pt));
    });

    test('putMany round-trips every entry in input order', () async {
      final entries = [
        for (var i = 0; i < 5; i++)
          (
            label: 'batch.$i',
            plaintext: Uint8List.fromList(List.filled(32, i)),
          ),
      ];
      final handles = await store.putMany(entries);
      expect(handles.length, 5);
      for (var i = 0; i < 5; i++) {
        expect(handles[i].label, 'batch.$i');
        final got =
            await store.use(handles[i], (b) async => Uint8List.fromList(b));
        expect(got, equals(entries[i].plaintext));
      }
    });

    test('use zeroes bytes after fn returns', () async {
      final pt = Uint8List.fromList(List.filled(32, 0xAB));
      final h = await store.put('test.k', pt);
      // Capture the buffer fn was given to assert post finally state
      Uint8List? captured;
      await store.use<void>(h, (b) async {
        captured = b;
      });
      expect(captured, isNotNull);
      expect(captured!.every((x) => x == 0), isTrue,
          reason: 'bytes must be zeroed after use<T> resolves');
    });

    test('delete then use throws KeyNotFoundException', () async {
      final h = await store.put('test.k', Uint8List(32));
      await store.delete(h);
      await expectLater(
          store.use(h, (_) async => 0), throwsA(isA<KeyNotFoundException>()));
    });

    test('list filters by labelPrefix', () async {
      await store.put('keepsy.opk.0', Uint8List(32));
      await store.put('keepsy.opk.1', Uint8List(32));
      await store.put('other.thing', Uint8List(32));
      final opks = await store.list(labelPrefix: 'keepsy.opk.');
      expect(opks.length, 2);
      final all = await store.list();
      expect(all.length, 3);
    });

    test('wipeAll clears prior handles; fresh put works after re-init',
        () async {
      final h = await store.put('test.k', Uint8List(32));
      await store.wipeAll();
      await store.initialize();
      await expectLater(
          store.use(h, (_) async => 0), throwsA(isA<KeyNotFoundException>()));
      final h2 = await store.put('test.k', Uint8List(32));
      expect(h2.id, isNotEmpty);
    });

    test('use without initialize throws KeyStoreUninitializedException',
        () async {
      final fresh = factory();
      await fresh.initialize();
      final h = await fresh.put('x', Uint8List(8));
      // wipeAll resets the mock's init flag : real impls drop the wrapper key
      // and surface E_STORE_UNINITIALIZED until initialize() runs again
      await fresh.wipeAll();
      await expectLater(fresh.use(h, (_) async => 0),
          throwsA(isA<KeyStoreUninitializedException>()));
    });
  });
}

void main() {
  runContractTests('MockSecureKeyStore', () => MockSecureKeyStore());
}
