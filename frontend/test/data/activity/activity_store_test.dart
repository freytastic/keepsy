import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:keepsy/data/storage/activity_store.dart';
import 'package:keepsy/domain/activity/activity_event.dart';
import 'package:keepsy/e2ee/media_record.dart';

import '../../_sodium_setup.dart';

void main() {
  late Directory dir;
  late ActivityStore store;
  final key = Uint8List.fromList(List.filled(32, 7));
  final at = DateTime.utc(2026, 9, 20, 10);

  setUpAll(() async {
    await ensureSodium();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('keepsy-activity');
    store = await ActivityStore.open(cacheRootKey: key, dir: dir);
  });

  tearDown(() async {
    await store.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  PhotosAdded photos(String id, {int count = 3, DateTime? when}) => PhotosAdded(
        id: id,
        albumId: 'album-1',
        at: when ?? at,
        count: count,
      );

  MemberJoined joined(String id) => MemberJoined(
        id: id,
        albumId: 'album-1',
        at: at,
        memberToken: 'noor',
      );

  test('a recorded event reads back with its detail intact', () async {
    await store.record([photos('added:1', count: 5)]);

    final rows = await store.read();
    expect(rows, hasLength(1));
    final e = rows.single.event as PhotosAdded;
    expect(e.id, 'added:1');
    expect(e.albumId, 'album-1');
    expect(e.count, 5);
    expect(rows.single.seen, isFalse);
  });

  test('preview records survive the seal', () async {
    final rec = MediaRecord(
      id: 'm1',
      albumId: 'album-1',
      uploaderToken: 'noor',
      wrapNonce: Uint8List(12),
      wrapTagCT: Uint8List(48),
      epochTag: 2,
      blobSize: 10,
      blobSha256: Uint8List(32),
      mediaType: 'photo',
      mimeType: 'image/jpeg',
      createdAt: at,
    );
    await store.record([
      PhotosAdded(
        id: 'added:p',
        albumId: 'album-1',
        at: at,
        count: 1,
        uploaderToken: 'noor',
        previews: [rec],
      ),
    ]);

    final back = (await store.read()).single.event as PhotosAdded;
    expect(back.previews.single.id, 'm1');
    expect(back.previews.single.epochTag, 2);
  });

  group('dismissal', () {
    SafetyNumberChanged trust(String id) => SafetyNumberChanged(
        id: id, albumId: 'album-1', at: at, peerToken: 'noor');

    test('a dismissed card reads back as dismissed', () async {
      await store.record([trust('t1'), trust('t2')]);
      await store.dismiss('t1');

      final rows = {for (final r in await store.read()) r.event.id: r};
      expect(rows['t1']!.dismissed, isTrue);
      expect(rows['t2']!.dismissed, isFalse);
    });

    test('survives a restart', () async {
      await store.record([trust('t1')]);
      await store.dismiss('t1');
      await store.close();
      store = await ActivityStore.open(cacheRootKey: key, dir: dir);

      expect((await store.read()).single.dismissed, isTrue);
    });

    test('re-recording does not bring the card back', () async {
      await store.record([trust('t1')]);
      await store.dismiss('t1');
      await store.record([trust('t1')]);

      expect((await store.read()).single.dismissed, isTrue);
    });

    test('a database from before dismissal is upgraded in place', () async {
      await store.record([trust('t1')]);
      await store.close();
      final path = '${dir.path}/activity.db';
      final old = await databaseFactory.openDatabase(path);
      await old.execute('ALTER TABLE activity DROP COLUMN dismissed');
      await old.setVersion(1);
      await old.close();

      store = await ActivityStore.open(cacheRootKey: key, dir: dir);
      expect((await store.read()).single.dismissed, isFalse);
      await store.dismiss('t1');
      expect((await store.read()).single.dismissed, isTrue);
    });
  });

  group('rewriting a row', () {
    MemberLeft left(String id, String album, {bool pending = true}) =>
        MemberLeft(
          id: id,
          albumId: album,
          at: at,
          memberToken: 'juno',
          rotationPending: pending,
        );

    test('settling a rotation clears only that album\'s pending rows',
        () async {
      await store.record([left('l1', 'a'), left('l2', 'b')]);
      await store.settleRotation('a');

      final rows = {
        for (final r in await store.read()) r.event.id: r.event as MemberLeft
      };
      expect(rows['l1']!.rotationPending, isFalse);
      expect(rows['l2']!.rotationPending, isTrue);
    });

    test('settling keeps read and dismissed state', () async {
      await store.record([left('l1', 'a')]);
      await store.markSeen(['l1']);
      await store.settleRotation('a');

      expect((await store.read()).single.seen, isTrue);
    });

    // Persist the alarm key so Compare cannot follow a changed roster
    test('a safety number change keeps the key it was raised for', () async {
      final ik = Uint8List.fromList(List.generate(32, (i) => i));
      await store.record([
        SafetyNumberChanged(
            id: 't', albumId: 'a', at: at, peerToken: 'noor', presentedIk: ik),
      ]);
      final back = (await store.read()).single.event as SafetyNumberChanged;
      expect(back.presentedIk, ik);
      expect(back.verified, isFalse);

      await store.resolveVerified(back);
      final after = (await store.read()).single;
      expect((after.event as SafetyNumberChanged).verified, isTrue);
      expect(after.dismissed, isTrue);
      expect(after.seen, isTrue);
    });
  });

  test('commit settles the named albums in the same transaction', () async {
    await store.record([
      MemberLeft(
          id: 'l1',
          albumId: 'a',
          at: at,
          memberToken: 'j',
          rotationPending: true),
      MemberLeft(
          id: 'l2',
          albumId: 'b',
          at: at,
          memberToken: 'j',
          rotationPending: true),
    ]);
    await store.commit(const [], {'s': 1}, settleAlbums: ['a']);

    final rows = {
      for (final r in await store.read()) r.event.id: r.event as MemberLeft
    };
    expect(rows['l1']!.rotationPending, isFalse);
    expect(rows['l2']!.rotationPending, isTrue);
    expect(await store.readSnapshot(), {'s': 1});
  });

  test('hasUnseen reflects what is actually stored', () async {
    expect(await store.hasUnseen(), isFalse);
    await store.record([photos('added:u')]);
    expect(await store.hasUnseen(), isTrue);
    await store.markSeen(['added:u']);
    expect(await store.hasUnseen(), isFalse);
  });

  group('a brand new account', () {
    test('starts from an empty baseline, not from never looked', () async {
      await store.seedEmptyBaseline();
      expect(await store.readSnapshot(), <String, dynamic>{});
    });

    test('never overwrites a baseline it already has', () async {
      await store.writeSnapshot({'a': 1});
      await store.seedEmptyBaseline();
      expect(await store.readSnapshot(), {'a': 1});
    });
  });

  test('commit writes the events and the snapshot', () async {
    await store.commit([photos('added:c')], {'a': 1});

    expect((await store.read()).single.event.id, 'added:c');
    expect(await store.readSnapshot(), {'a': 1});
  });

  // A row that will not decrypt is never shown, so it must not hold the
  // unread dot on forever either
  test('an unreadable row is not counted as unread', () async {
    await store.record([photos('added:ok')]);
    await store.close();
    final raw = await databaseFactory.openDatabase('${dir.path}/activity.db');
    await raw.insert('activity', {
      'row_key': 'garbage',
      'lane': ActivityLane.albums.index,
      'at': 0,
      'seen': 0,
      'dismissed': 0,
      'payload': Uint8List.fromList(List.filled(40, 1)),
    });
    await raw.close();
    store = await ActivityStore.open(cacheRootKey: key, dir: dir);

    expect(await store.unseenCount(ActivityLane.albums), 1);
  });

  test('recording the same id twice keeps one row', () async {
    await store.record([photos('added:1')]);
    await store.record([photos('added:1')]);

    expect(await store.read(), hasLength(1));
  });

  test('a re-recorded event does not come back unread', () async {
    await store.record([photos('added:1')]);
    await store.markSeen(['added:1']);
    await store.record([photos('added:1')]);

    expect((await store.read()).single.seen, isTrue);
  });

  test('rows are counted unseen per lane', () async {
    await store.record([photos('added:1'), joined('joined:1')]);

    expect(await store.unseenCount(ActivityLane.albums), 1);
    expect(await store.unseenCount(ActivityLane.security), 1);

    await store.markSeen(['added:1']);
    expect(await store.unseenCount(ActivityLane.albums), 0);
    expect(await store.unseenCount(ActivityLane.security), 1);
  });

  test('reading one lane leaves the other alone', () async {
    await store.record([photos('added:1'), joined('joined:1')]);

    final albums = await store.read(lane: ActivityLane.albums);
    expect(albums.single.event, isA<PhotosAdded>());

    final security = await store.read(lane: ActivityLane.security);
    expect(security.single.event, isA<MemberJoined>());
  });

  test('newest rows come back first', () async {
    await store.record([
      photos('old', when: DateTime.utc(2026, 9, 1)),
      photos('new', when: DateTime.utc(2026, 9, 19)),
    ]);

    expect((await store.read()).map((r) => r.event.id), ['new', 'old']);
  });

  group('retention', () {
    test('album rows older than the window are dropped', () async {
      await store.record([photos('stale', when: DateTime.utc(2026, 1, 1))]);
      await store.prune(albumRowsBefore: DateTime.utc(2026, 6, 1));

      expect(await store.read(), isEmpty);
    });

    // Anything that touched who can read your albums stays on the record
    test('security rows are never dropped, however old', () async {
      await store.record([
        MemberLeft(
          id: 'left:ancient',
          albumId: 'album-1',
          at: DateTime.utc(2020, 1, 1),
          memberToken: 'juno',
        ),
      ]);
      await store.prune(albumRowsBefore: DateTime.utc(2026, 9, 1));

      expect(await store.read(), hasLength(1));
    });
  });

  group('the shelf snapshot', () {
    test('round trips through a reopen', () async {
      await store.writeSnapshot({
        'a': {
          'media_count': 5,
          'members': ['noor']
        }
      });
      await store.close();
      store = await ActivityStore.open(cacheRootKey: key, dir: dir);

      final got = await store.readSnapshot();
      expect((got!['a'] as Map)['media_count'], 5);
    });

    test('is absent before anything has looked', () async {
      expect(await store.readSnapshot(), isNull);
    });

    // The snapshot contains album ids and member tokens
    test('is not readable in the database file', () async {
      await store.writeSnapshot({
        'the-secret-album': {
          'members': ['the-secret-member']
        }
      });
      await store.close();

      final text = String.fromCharCodes(
          File('${dir.path}/activity.db').readAsBytesSync());
      expect(text.contains('the-secret-album'), isFalse);
      expect(text.contains('the-secret-member'), isFalse);

      store = await ActivityStore.open(cacheRootKey: key, dir: dir);
    });
  });

  // The row content is the social graph the server-side table was deleted for
  test('nothing readable is written to the database file', () async {
    await store.record([
      MemberJoined(
        id: 'joined:leaky',
        albumId: 'the-secret-album',
        at: at,
        memberToken: 'the-secret-member',
      ),
    ]);
    await store.close();

    final bytes = File('${dir.path}/activity.db').readAsBytesSync();
    final text = String.fromCharCodes(bytes);
    expect(text.contains('the-secret-album'), isFalse);
    expect(text.contains('the-secret-member'), isFalse);
    expect(text.contains('joined:leaky'), isFalse);

    store = await ActivityStore.open(cacheRootKey: key, dir: dir);
  });
}
