import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/ui/album/album_stats.dart';

MediaRecord _shot(String id, String by, {int blob = 1000, int? thumb = 100}) =>
    MediaRecord(
      id: id,
      albumId: 'album-1',
      uploaderToken: by,
      wrapNonce: Uint8List(12),
      wrapTagCT: Uint8List(48),
      epochTag: 0,
      blobSize: blob,
      blobSha256: Uint8List(32),
      mediaType: 'photo',
      mimeType: 'image/jpeg',
      createdAt: DateTime(2026),
      thumbSize: thumb,
      thumbWrapNonce: thumb == null ? null : Uint8List(12),
      thumbWrapTagCT: thumb == null ? null : Uint8List(48),
      thumbSha256: thumb == null ? null : Uint8List(32),
    );

void main() {
  test('formatBytes matches the mock thresholds', () {
    expect(AlbumStats.formatBytes(0), '0 KB');
    expect(AlbumStats.formatBytes(999999), '1000 KB');
    expect(AlbumStats.formatBytes(1500000), '1.5 MB');
    expect(AlbumStats.formatBytes(12400000), '12 MB');
    expect(AlbumStats.formatBytes(2300000000), '2.3 GB');
  });

  group('totals', () {
    test('counts file and thumbnail bytes', () {
      final stats = AlbumStats.of(
        [_shot('a', 'alice'), _shot('b', 'bob', thumb: null)],
        peopleCount: 2,
      );

      expect(stats.photoCount, 2);
      expect(stats.totalBytes, 1000 + 100 + 1000);
    });
  });

  group('per uploader', () {
    test('groups bytes and counts by who sent them', () {
      final stats = AlbumStats.of([
        _shot('a', 'alice', blob: 1000),
        _shot('b', 'alice', blob: 3000),
        _shot('c', 'bob', blob: 500),
      ], peopleCount: 2);

      expect(stats.perUploader['alice']!.photos, 2);
      expect(stats.perUploader['alice']!.bytes, 1000 + 100 + 3000 + 100);
      expect(stats.perUploader['bob']!.photos, 1);
    });

    test('the heaviest uploader comes first', () {
      final stats = AlbumStats.of([
        _shot('a', 'small', blob: 100),
        _shot('b', 'large', blob: 9000),
      ], peopleCount: 2);

      expect(stats.byWeight.first.key, 'large');
    });
  });

  test('summary handles populated and empty albums', () {
    final stats = AlbumStats.of(
      [_shot('a', 'alice', blob: 1400000, thumb: null)],
      peopleCount: 3,
    );
    final empty = AlbumStats.of(const [], peopleCount: 2);

    expect(stats.summary(), '1 photo · 1.4 MB · 3 people');
    expect(empty.summary(invited: 3), '2 people, 3 invited');
  });
}
