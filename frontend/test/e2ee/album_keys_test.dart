import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/e2ee/album_keys.dart';

import '../secure_store/mock_secure_key_store.dart';

Uint8List _albumId([int seed = 0xA1]) =>
    Uint8List.fromList(List<int>.filled(16, seed));

Uint8List _mk(int b) => Uint8List.fromList(List<int>.filled(32, b));

Future<AlbumKeyStore> _newStore([MockSecureKeyStore? store]) async {
  final s = store ?? MockSecureKeyStore();
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
      expect(await aks.presentEpochs(b), [0]);

      final aks2 = AlbumKeyStore(shared);
      await aks2.initialize();
      expect(await aks2.presentEpochs(a), isEmpty);
      expect(await aks2.presentEpochs(b), [0]);
    });

    test('deleting an album with no MKs is a no-op', () async {
      final aks = await _newStore();
      await aks.deleteAlbumMKs(_albumId(0xC3));
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
        expect(mk.length, 32);
        expect(mk.every((b) => b == 0x42), isTrue);
        captured = mk;
        return mk[0];
      });
      expect(got, 0x42);
      expect(captured!.every((b) => b == 0), isTrue);
    });

    test('overlapping callers share one key store read', () async {
      final store = MockSecureKeyStore();
      final aks = await _newStore(store);
      final id = _albumId();
      await aks.installVerified(
          albumId: id, epoch: 0, mk: _mk(0x42), backfill: false);
      store.getOnceCalls = 0;

      final seen = <Uint8List>[];
      final results = await Future.wait([
        for (var i = 0; i < 5; i++)
          aks.useMk<int>(id, 0, (mk) async {
            seen.add(mk);
            await Future<void>.delayed(Duration(milliseconds: 5 * i));
            return mk.every((b) => b == 0x42) ? 1 : 0;
          }),
      ]);

      expect(results, everyElement(1),
          reason: 'no caller may see bytes zeroed under it');
      expect(store.getOnceCalls, 1);
      for (final mk in seen) {
        expect(mk.every((b) => b == 0), isTrue);
      }
    });

    test('a caller after the last one finished reads again', () async {
      final store = MockSecureKeyStore();
      final aks = await _newStore(store);
      final id = _albumId();
      await aks.installVerified(
          albumId: id, epoch: 0, mk: _mk(0x42), backfill: false);
      store.getOnceCalls = 0;

      await aks.useMk<void>(id, 0, (_) async {});
      await aks.useMk<void>(id, 0, (_) async {});

      expect(store.getOnceCalls, 2);
    });

    test('different epochs never share bytes', () async {
      final aks = await _newStore();
      final id = _albumId();
      await aks.installVerified(
          albumId: id, epoch: 0, mk: _mk(0x10), backfill: false);
      await aks.installVerified(
          albumId: id, epoch: 1, mk: _mk(0x11), backfill: false);

      final got = await Future.wait([
        aks.useMk<int>(id, 0, (mk) async => mk[0]),
        aks.useMk<int>(id, 1, (mk) async => mk[0]),
      ]);

      expect(got, [0x10, 0x11]);
    });

    test('a failed read reaches every overlapping caller', () async {
      final store = MockSecureKeyStore();
      final aks = await _newStore(store);
      final id = _albumId();
      await aks.installVerified(
          albumId: id, epoch: 0, mk: _mk(0x42), backfill: false);
      final handle = (await store.list(labelPrefix: kAlbumLabelPrefix)).single;
      await store.delete(handle);

      final a = aks.useMk<int>(id, 0, (mk) async => 1);
      final b = aks.useMk<int>(id, 0, (mk) async => 1);
      await expectLater(a, throwsA(anything));
      await expectLater(b, throwsA(anything));
    });
  });
}
