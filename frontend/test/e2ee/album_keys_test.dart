import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/album_keys.dart';

import '../secure_store/mock_secure_key_store.dart';

Uint8List _albumId([int seed = 0xA1]) =>
    Uint8List.fromList(List<int>.filled(16, seed));

Uint8List _mk(int b) => Uint8List.fromList(List<int>.filled(32, b));

Future<AlbumKeyStore> _newStore() async {
  final s = MockSecureKeyStore();
  await s.initialize();
  final aks = AlbumKeyStore(s);
  await aks.initialize();
  return aks;
}

void main() {
  group('AlbumKeyStore.installVerified', () {
    test('rejects downgrade after MK_5', () async {
      final aks = await _newStore();
      final id = _albumId();
      await aks.installVerified(
          albumId: id, epoch: 5, mk: _mk(0x55), backfill: false);
      await expectLater(
        aks.installVerified(
            albumId: id, epoch: 3, mk: _mk(0x33), backfill: false),
        throwsA(isA<EpochReplayException>()
            .having((e) => e.reason, 'reason', 'downgrade')
            .having((e) => e.epoch, 'epoch', 3)
            .having((e) => e.latestEpoch, 'latestEpoch', 5)),
      );
      // backfill=true still bypasses (Phase 6 flow)
      await aks.installVerified(
          albumId: id, epoch: 3, mk: _mk(0x33), backfill: true);
      expect(await aks.presentEpochs(id), [3, 5]);
    });

    test('rejects byte mismatch on same epoch as tamper', () async {
      final aks = await _newStore();
      final id = _albumId();
      await aks.installVerified(
          albumId: id, epoch: 5, mk: _mk(0xAA), backfill: false);
      await expectLater(
        aks.installVerified(
            albumId: id, epoch: 5, mk: _mk(0xBB), backfill: false),
        throwsA(isA<EpochReplayException>()
            .having((e) => e.reason, 'reason', 'tamper')),
      );
    });

    test('idempotent on byte equal re install', () async {
      final aks = await _newStore();
      final id = _albumId();
      await aks.installVerified(
          albumId: id, epoch: 5, mk: _mk(0xCC), backfill: false);
      await aks.installVerified(
          albumId: id, epoch: 5, mk: _mk(0xCC), backfill: false);
      expect(await aks.presentEpochs(id), [5]);
      expect(await aks.latestEpoch(id), 5);
    });
  });

  group('AlbumKeyStore.initialize', () {
    test('reproduces presence map from SecureKeyStore.list()', () async {
      final shared = MockSecureKeyStore();
      await shared.initialize();
      final aks1 = AlbumKeyStore(shared);
      await aks1.initialize();
      final id = _albumId(0x77);
      await aks1.installVerified(
          albumId: id, epoch: 0, mk: _mk(0x10), backfill: false);
      await aks1.installVerified(
          albumId: id, epoch: 4, mk: _mk(0x14), backfill: false);
      await aks1.installVerified(
          albumId: id, epoch: 9, mk: _mk(0x19), backfill: false);

      // Fresh AlbumKeyStore over the same SecureKeyStore : presence rebuilt
      // from labels alone, no in memory carry over
      final aks2 = AlbumKeyStore(shared);
      await aks2.initialize();
      expect(await aks2.presentEpochs(id), [0, 4, 9]);
      expect(await aks2.latestEpoch(id), 9);
    });
  });

  group('AlbumKeyStore.deleteAlbumMKs', () {
    test('drops every MK for the album and leaves other albums intact',
        () async {
      final shared = MockSecureKeyStore();
      await shared.initialize();
      final aks = AlbumKeyStore(shared);
      await aks.initialize();
      final a = _albumId(0xA1);
      final b = _albumId(0xB2);
      await aks.install(a, 0, _mk(0x01));
      await aks.install(a, 1, _mk(0x02));
      await aks.install(b, 0, _mk(0x03));

      await aks.deleteAlbumMKs(a);

      expect(await aks.presentEpochs(a), isEmpty);
      expect(await aks.latestEpoch(a), -1);
      expect(await aks.presentEpochs(b), [0]); // untouched

      // Persisted, not just the in memory map: a fresh store over the same
      // backing SecureKeyStore rebuilds with album a's labels gone
      final aks2 = AlbumKeyStore(shared);
      await aks2.initialize();
      expect(await aks2.presentEpochs(a), isEmpty);
      expect(await aks2.presentEpochs(b), [0]);
    });

    test('deleting an album with no MKs is a no-op', () async {
      final aks = await _newStore();
      await aks.deleteAlbumMKs(_albumId(0xC3)); // must not throw
      expect(await aks.presentEpochs(_albumId(0xC3)), isEmpty);
    });
  });

  group('AlbumKeyStore.useMk', () {
    test('zeroes the buffer in finally (mirrors §2.1 contract)', () async {
      final aks = await _newStore();
      final id = _albumId();
      await aks.installVerified(
          albumId: id, epoch: 1, mk: _mk(0x42), backfill: false);

      Uint8List? captured;
      final got = await aks.useMk<int>(id, 1, (mk) async {
        // Inside the callback, the buffer carries the real MK
        expect(mk.length, 32);
        expect(mk.every((b) => b == 0x42), isTrue);
        captured = mk; // hold a reference so we can inspect after finally
        return mk[0];
      });
      expect(got, 0x42);
      // After useMk returns, the buffer SecureKeyStore handed in must be zero
      expect(captured!.every((b) => b == 0), isTrue);
    });
  });
}
