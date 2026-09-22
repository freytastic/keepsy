import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/models/album_summary.dart';
import 'package:keepsy/domain/activity/activity_event.dart';
import 'package:keepsy/domain/activity/activity_recorder.dart';
import 'package:keepsy/e2ee/media_record.dart';

class _Sink {
  final List<ActivityEvent> recorded = [];
  Map<String, dynamic>? snapshot;
}

void main() {
  AlbumModel album(
    String id, {
    int media = 0,
    int generation = 1,
    List<String> members = const ['me'],
    String role = 'member',
    String? self,
    bool rotation = false,
    int? active,
  }) =>
      AlbumModel(
        id: id,
        activeMemberCount: active ?? members.length,
        memberToken: self,
        rotationRequired: rotation,
        nameCt: null,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        myRole: role,
        mediaCount: media,
        mediaGeneration: generation,
        memberPreviews: [
          for (final m in members) MemberPreview(memberToken: m),
        ],
        hasSummary: true,
      );

  late _Sink sink;
  late List<String> settled;

  ActivityRecorder recorder({
    Map<String, List<MediaRecord>>? media,
    List<String>? fetched,
  }) =>
      ActivityRecorder(
        fetchMedia: media == null
            ? null
            : (albumId) async {
                fetched?.add(albumId);
                return media[albumId];
              },
        record: (events) async => sink.recorded.addAll(events),
        readSnapshot: () async => sink.snapshot,
        writeSnapshot: (s) async => sink.snapshot = s,
        settleRotation: (albumId) async => settled.add(albumId),
        now: () => DateTime.utc(2026, 9, 21),
      );

  MediaRecord shot(String id, String uploader, int seq) => MediaRecord(
        id: id,
        albumId: 'a',
        uploaderToken: uploader,
        wrapNonce: Uint8List(12),
        wrapTagCT: Uint8List(48),
        epochTag: 1,
        blobSize: 10,
        blobSha256: Uint8List(32),
        mediaType: 'photo',
        mimeType: 'image/jpeg',
        createdAt: DateTime.utc(2026, 9, 20, 10),
        albumSeq: seq,
      );

  setUp(() {
    sink = _Sink();
    settled = [];
  });

  test('the first pass records nothing and stores the baseline', () async {
    await recorder().observe([album('a', media: 40)]);

    expect(sink.recorded, isEmpty);
    expect(sink.snapshot, isNotNull);
  });

  test('the second pass reports what moved', () async {
    final r = recorder();
    await r.observe([album('a', media: 3)]);
    await r.observe([album('a', media: 8, generation: 6)]);

    final e = sink.recorded.single as PhotosAdded;
    expect(e.count, 5);
  });

  test('observing the same shelf twice reports nothing the second time',
      () async {
    final r = recorder();
    await r.observe([album('a', media: 3)]);
    await r.observe([album('a', media: 8, generation: 2)]);
    sink.recorded.clear();
    await r.observe([album('a', media: 8, generation: 2)]);

    expect(sink.recorded, isEmpty);
  });

  test('an album without a summary is left out of the comparison', () async {
    final r = recorder();
    await r.observe([album('a', media: 8)]);

    final thin = AlbumModel(
      id: 'a',
      nameCt: null,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    await r.observe([thin]);

    expect(sink.recorded, isEmpty);
    // The good snapshot survives for the next authoritative listing
    await r.observe([album('a', media: 10, generation: 3)]);
    expect((sink.recorded.single as PhotosAdded).count, 2);
  });

  group('attribution', () {
    test('names the uploader when media can be fetched', () async {
      final r = recorder(media: {
        'a': [shot('m2', 'noor', 3), shot('m1', 'noor', 2)]
      });
      await r.observe([album('a', media: 3)]);
      await r.observe([album('a', media: 5, generation: 3)]);

      final e = sink.recorded.single as PhotosAdded;
      expect(e.uploaderToken, 'noor');
      expect(e.count, 2);
    });

    test('only fetches albums whose media changed', () async {
      final fetched = <String>[];
      final r = recorder(media: {
        'a': [shot('m1', 'noor', 2)]
      }, fetched: fetched);
      await r.observe([album('a', media: 3), album('b', media: 9)]);
      await r.observe([
        album('a', media: 4, generation: 2),
        album('b', media: 9),
      ]);

      expect(fetched, ['a']);
    });

    test('does not fetch when only the member set moved', () async {
      final fetched = <String>[];
      final r = recorder(media: const {}, fetched: fetched);
      await r.observe([
        album('a', members: ['me'])
      ]);
      await r.observe([
        album('a', members: ['me', 'noor'])
      ]);

      expect(fetched, isEmpty);
      expect(sink.recorded.single, isA<MemberJoined>());
    });

    test('keeps the unattributed row when the fetch returns nothing', () async {
      final r = recorder(media: const {});
      await r.observe([album('a', media: 3)]);
      await r.observe([album('a', media: 8, generation: 6)]);

      final e = sink.recorded.single as PhotosAdded;
      expect(e.uploaderToken, isNull);
      expect(e.count, 5);
    });
  });

  test('an owner hears about photos a member added before the next look',
      () async {
    final r = recorder(media: {
      'a': [shot('m3', 'noor', 3), shot('m2', 'noor', 2), shot('m1', 'me', 1)]
    });
    await r.observe([]);
    await r.observe([
      album('a',
          media: 3,
          generation: 3,
          members: ['me', 'noor'],
          role: 'admin',
          self: 'me'),
    ]);

    final photos = sink.recorded.whereType<PhotosAdded>().single;
    expect(photos.uploaderToken, 'noor');
    expect(photos.count, 2, reason: 'your own upload is not news to you');
    expect(sink.recorded.whereType<MemberJoined>().single.memberToken, 'noor');
  });

  test('the self token survives the snapshot', () async {
    await recorder().observe([]);
    await recorder().observe([
      album('a', role: 'admin', members: ['me'], self: 'me')
    ]);
    sink.recorded.clear();
    await recorder().observe([
      album('a', role: 'admin', members: ['me', 'sam'], self: 'me')
    ]);

    expect(sink.recorded.single, isA<MemberJoined>());
  });

  test('a snapshot round trips through storage', () async {
    await recorder().observe([
      album('a', media: 3, members: ['me', 'noor'])
    ]);

    await recorder().observe([
      album('a', media: 5, generation: 3, members: ['me', 'noor'])
    ]);

    expect((sink.recorded.single as PhotosAdded).count, 2);
  });

  // A departure recorded while the rotation was owed would otherwise warn
  // forever: once the member is gone, nothing about them changes again
  group('a finished rotation', () {
    test('settles the album\'s pending departures', () async {
      final r = recorder();
      await r.observe([
        album('a', members: ['me'], rotation: true)
      ]);
      await r.observe([
        album('a', members: ['me'])
      ]);

      expect(settled, ['a']);
    });

    test('an album whose rotation is still owed is left alone', () async {
      final r = recorder();
      await r.observe([album('a', rotation: true)]);
      await r.observe([album('a', rotation: true)]);

      expect(settled, isEmpty);
    });
  });

  // Timestamped ids would duplicate a row if a crash landed between recording
  // it and saving the snapshot, so both go down in one transaction
  test('events and the snapshot are committed together', () async {
    final commits = <(List<ActivityEvent>, Map<String, dynamic>)>[];
    final r = ActivityRecorder(
      record: (_) async => fail('separate record must not be used'),
      readSnapshot: () async => sink.snapshot,
      writeSnapshot: (_) async => fail('separate write must not be used'),
      commit: (events, snapshot, {settleAlbums = const []}) async {
        commits.add((events, snapshot));
        sink.snapshot = snapshot;
      },
      now: () => DateTime.utc(2026, 9, 21),
    );
    await r.observe([
      album('a', members: ['me'])
    ]);
    await r.observe([
      album('a', members: ['me', 'noor'])
    ]);

    expect(commits, hasLength(2));
    expect(commits.last.$1.single, isA<MemberJoined>());
    expect(commits.last.$2.keys, ['a']);
  });

  // An older server lists at most four members. A roster shorter than the
  // album's member count is not the roster, so it must never produce joins
  // or departures: a fifth member sliding into view is not someone joining
  group('a partial member list', () {
    test('produces no membership rows', () async {
      final r = recorder();
      await r.observe([
        album('a', members: ['me', 'b', 'c', 'd'], active: 6)
      ]);
      await r.observe([
        album('a', members: ['me', 'c', 'd', 'e'], active: 6)
      ]);

      expect(sink.recorded, isEmpty);
    });

    test('still reports photos', () async {
      final r = recorder();
      await r.observe([
        album('a', members: ['me', 'b', 'c', 'd'], active: 6)
      ]);
      await r.observe([
        album('a',
            members: ['me', 'b', 'c', 'd'], active: 6, media: 2, generation: 3)
      ]);

      expect(sink.recorded.single, isA<PhotosAdded>());
    });

    test('a complete list after a partial one is not a wave of joins',
        () async {
      final r = recorder();
      await r.observe([
        album('a', members: ['me', 'b', 'c', 'd'], active: 6)
      ]);
      await r.observe([
        album('a', members: ['me', 'b', 'c', 'd', 'e', 'f'], active: 6)
      ]);

      expect(sink.recorded, isEmpty);
    });
  });

  // Settling after the commit lost the true to false transition on a crash,
  // leaving "the new key is not finished" up forever
  test('rotation settlement rides in the same commit', () async {
    final settledInCommit = <List<String>>[];
    final r = ActivityRecorder(
      record: (_) async => fail('separate record must not be used'),
      readSnapshot: () async => sink.snapshot,
      writeSnapshot: (_) async => fail('separate write must not be used'),
      settleRotation: (_) async => fail('settle must ride in the commit'),
      commit: (events, snapshot, {settleAlbums = const []}) async {
        settledInCommit.add(settleAlbums);
        sink.snapshot = snapshot;
      },
      now: () => DateTime.utc(2026, 9, 21),
    );
    await r.observe([album('a', rotation: true)]);
    await r.observe([album('a')]);

    expect(settledInCommit.last, ['a']);
  });
}
