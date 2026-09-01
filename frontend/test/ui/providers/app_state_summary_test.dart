import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/models/album_summary.dart';
import 'package:keepsy/ui/providers/app_state.dart';

PreviewMedia _preview(String id) => PreviewMedia(
      mediaId: id,
      epochTag: 0,
      thumbWrapNonce: Uint8List(12),
      thumbWrapTagCT: Uint8List(48),
      thumbSize: 10,
      thumbSha256: Uint8List(32),
    );

AlbumModel _album({
  String id = 'a1',
  int mediaCount = 4,
  int generation = 4,
  List<PreviewMedia> preview = const [],
  bool hasSummary = true,
}) =>
    AlbumModel(
      id: id,
      nameCt: null,
      createdAt: DateTime(2026, 8, 1),
      updatedAt: DateTime(2026, 8, 1),
      mediaCount: mediaCount,
      activeMemberCount: 2,
      latestActivityAt: DateTime(2026, 8, 20),
      mediaGeneration: generation,
      previewMedia: preview,
      hasSummary: hasSummary,
    );

void main() {
  group('applyMediaAdded', () {
    test('a live upload moves the generation and the count', () {
      final state = AppState()..setAlbums([_album()]);
      state.applyMediaAdded('a1', 5);

      final a = state.albums.single;
      expect(a.mediaGeneration, 5);
      expect(a.mediaCount, 5);
      expect(a.latestActivityAt!.isAfter(DateTime(2026, 8, 20)), isTrue);
    });

    test('the album moves to the front of the shelf', () {
      final state = AppState()
        ..setAlbums([_album(id: 'a1'), _album(id: 'a2'), _album(id: 'a3')]);
      state.applyMediaAdded('a3', 5);

      expect([for (final a in state.albums) a.id], ['a3', 'a1', 'a2']);
      expect(state.albums.length, 3, reason: 'moved, not duplicated');
    });

    test('the arriving frame becomes the cover', () {
      final state = AppState()
        ..setAlbums([
          _album(preview: [_preview('old1'), _preview('old2')])
        ]);
      state.applyMediaAdded('a1', 5, preview: _preview('new1'));

      expect([for (final p in state.albums.single.previewMedia) p.mediaId],
          ['new1', 'old1', 'old2']);
    });

    test('the preview list stays at three', () {
      final state = AppState()
        ..setAlbums([
          _album(preview: [_preview('m1'), _preview('m2'), _preview('m3')])
        ]);
      state.applyMediaAdded('a1', 5, preview: _preview('m4'));

      expect([for (final p in state.albums.single.previewMedia) p.mediaId],
          ['m4', 'm1', 'm2']);
    });

    test('a gap larger than one asks for the real summary', () async {
      var refreshed = 0;
      final state = AppState(summaryDebounce: const Duration(milliseconds: 10))
        ..setAlbums([_album(generation: 4)]);
      state.attachSummaryRefresh(() async => refreshed++);

      state.applyMediaAdded('a1', 5);
      state.applyMediaAdded('a1', 9);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(refreshed, 1,
          reason: 'one debounced refresh for the burst, not one per frame');
    });

    test('a single step needs no refresh', () async {
      var refreshed = 0;
      final state = AppState(summaryDebounce: const Duration(milliseconds: 10))
        ..setAlbums([_album(generation: 4)]);
      state.attachSummaryRefresh(() async => refreshed++);

      state.applyMediaAdded('a1', 5);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(refreshed, 0);
    });

    test('a replayed or stale event changes nothing', () {
      final state = AppState()..setAlbums([_album()]);
      state.applyMediaAdded('a1', 4);
      state.applyMediaAdded('a1', 2);
      expect(state.albums.single.mediaGeneration, 4);
      expect(state.albums.single.mediaCount, 4);
    });

    test('an album we do not hold is ignored', () {
      final state = AppState()..setAlbums([_album()]);
      state.applyMediaAdded('nope', 9);
      expect(state.albums.single.mediaGeneration, 4);
    });
  });

  group('PreviewMedia.tryFromRecordJson', () {
    Map<String, dynamic> record({bool thumb = true}) => {
          'id': 'm1',
          'album_id': 'a1',
          'epoch_tag': 2,
          if (thumb) ...{
            'thumb_wrap_nonce': base64.encode(Uint8List(12)),
            'thumb_wrap_tag_ct': base64.encode(Uint8List(48)),
            'thumb_size': 900,
            'thumb_sha256': base64.encode(Uint8List(32)),
          },
        };

    test('reads the thumb half of a media_added record', () {
      final p = PreviewMedia.tryFromRecordJson(record())!;
      expect(p.mediaId, 'm1');
      expect(p.epochTag, 2);
      expect(p.thumbSize, 900);
    });

    test('a frame with no thumb is not a cover', () {
      expect(PreviewMedia.tryFromRecordJson(record(thumb: false)), isNull);
    });

    test('a malformed record is null rather than a throw', () {
      expect(PreviewMedia.tryFromRecordJson({'id': 'm1'}), isNull);
    });
  });

  group('member names', () {
    test('a resolve landing after removal does not restore the name', () async {
      final gate = Completer<String?>();
      final state = AppState()
        ..setAlbums([
          AlbumModel(
            id: 'a1',
            nameCt: null,
            createdAt: DateTime(2026, 8, 1),
            updatedAt: DateTime(2026, 8, 1),
            memberPreviews: const [
              MemberPreview(memberToken: 'tok', nameCt: 'x')
            ],
          )
        ]);
      state.attachMemberNameResolver((album, token, ct) => gate.future);
      await Future<void>.microtask(() {});

      state.removeAlbum('a1');
      gate.complete('Sam');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(state.memberDisplayName('a1', 'tok'), isNull,
          reason: 'an in flight resolver must not undo the wipe');
    });
  });

  group('setAlbums is monotonic', () {
    test('a stale response cannot roll the generation back', () {
      final state = AppState()..setAlbums([_album(generation: 4)]);
      state.applyMediaAdded('a1', 9, preview: _preview('new1'));

      state.setAlbums([_album(generation: 8, mediaCount: 8)]);

      final a = state.albums.single;
      expect(a.mediaGeneration, 9);
      expect(a.previewMedia.single.mediaId, 'new1',
          reason: 'the older cover must not come back');
    });

    test('an album held ahead keeps its place at the front', () {
      final state = AppState()
        ..setAlbums([_album(id: 'a1'), _album(id: 'a2'), _album(id: 'a3')]);
      state.applyMediaAdded('a3', 9);
      expect(state.albums.first.id, 'a3');

      state.setAlbums([
        _album(id: 'a1'),
        _album(id: 'a2'),
        _album(id: 'a3', generation: 4),
      ]);
      expect(state.albums.first.id, 'a3',
          reason: 'realtime already moved it; a stale list must not undo that');
    });

    test('a newer response is taken as it stands', () {
      final state = AppState()..setAlbums([_album(generation: 4)]);
      state.setAlbums([
        _album(generation: 12, mediaCount: 12, preview: [_preview('m9')])
      ]);

      final a = state.albums.single;
      expect(a.mediaGeneration, 12);
      expect(a.previewMedia.single.mediaId, 'm9');
    });

    test('a summary-less response is not treated as a rollback', () {
      final state = AppState()..setAlbums([_album(generation: 9)]);
      state.setAlbums([_album(generation: 0, hasSummary: false)]);
      expect(state.albums.single.hasSummary, isFalse);
    });
  });
}
