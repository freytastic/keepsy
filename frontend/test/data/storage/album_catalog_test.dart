import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/models/album_summary.dart';
import 'package:keepsy/data/storage/media_cache_key.dart';
import 'package:keepsy/data/storage/media_sealed_cache.dart';
import 'package:keepsy/e2ee/media_record.dart';

Uint8List _key([int fill = 0x11]) =>
    Uint8List.fromList(List<int>.filled(32, fill));

AlbumModel _album(String id, {String? nameCt, int generation = 0}) =>
    AlbumModel(
      id: id,
      nameCt: nameCt,
      createdAt: DateTime.utc(2026, 9, 1),
      updatedAt: DateTime.utc(2026, 9, 2),
      memberToken: 'tok-$id',
      mediaCount: 3,
      activeMemberCount: 2,
      latestActivityAt: DateTime.utc(2026, 9, 3),
      mediaGeneration: generation,
      hasSummary: true,
      previewMedia: [
        PreviewMedia(
          mediaId: 'p-$id',
          epochTag: 0,
          thumbWrapNonce: Uint8List(12),
          thumbWrapTagCT: Uint8List(48),
          thumbSize: 42,
          thumbSha256: Uint8List(32),
        )
      ],
      memberPreviews: const [
        MemberPreview(memberToken: 'mt1', nameCt: 'ct1'),
      ],
    );

MediaRecord _rec(String id, String album) => MediaRecord(
      id: id,
      albumId: album,
      uploaderToken: 'tok',
      wrapNonce: Uint8List(12),
      wrapTagCT: Uint8List(48),
      epochTag: 0,
      blobSize: 10,
      blobSha256: Uint8List(32),
      mediaType: 'photo',
      mimeType: 'image/jpeg',
      createdAt: DateTime.utc(2026, 9, 1),
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory durable;
  late Directory disposable;

  setUp(() {
    durable = Directory.systemTemp.createTempSync('ac_dur_');
    disposable = Directory.systemTemp.createTempSync('ac_cache_');
  });

  tearDown(() {
    if (durable.existsSync()) durable.deleteSync(recursive: true);
    if (disposable.existsSync()) disposable.deleteSync(recursive: true);
  });

  Future<MediaSealedCache> openCache() => MediaSealedCache.open(
      rootDir: disposable, durableDir: durable, cacheRootKey: _key());

  test('the album shelf survives a restart with its order intact', () async {
    var c = await openCache();
    await c.saveAlbums([_album('a1', nameCt: 'n1'), _album('a2')]);
    await c.close();

    c = await openCache();
    addTearDown(c.close);
    final loaded = await c.loadAlbums();

    expect(loaded.map((a) => a.id), ['a1', 'a2']);
    expect(loaded.first.nameCt, 'n1');
    expect(loaded.first.memberToken, 'tok-a1');
    expect(loaded.first.mediaCount, 3);
    expect(loaded.first.hasSummary, isTrue);
    expect(loaded.first.previewMedia.single.mediaId, 'p-a1');
    expect(loaded.first.previewMedia.single.thumbSize, 42);
    expect(loaded.first.memberPreviews.single.memberToken, 'mt1');
  });

  test('saving a new shelf replaces the albums no longer listed', () async {
    final c = await openCache();
    addTearDown(c.close);
    await c.saveAlbums([_album('a1'), _album('a2')]);
    await c.saveAlbums([_album('a2')]);

    expect((await c.loadAlbums()).map((a) => a.id), ['a2']);
  });

  test('a revoked album cannot come back from disk after a restart', () async {
    var c = await openCache();
    await c.saveAlbums([_album('a1'), _album('a2')]);
    await c.writeRecord(_rec('m1', 'a1'));
    await c.writeBlob(
        MediaCacheKey(
            albumId: 'a1', mediaId: 'm1', epochTag: 0, asset: CacheAsset.thumb),
        Uint8List.fromList(List.filled(40, 7)));

    await c.clearAlbum('a1');
    await c.dropAlbum('a1');
    await c.close();

    // Reopen offline : nothing may resurrect the album
    c = await openCache();
    addTearDown(c.close);

    expect((await c.loadAlbums()).map((a) => a.id), ['a2']);
    expect(await c.listRecordsForAlbum('a1'), isEmpty);
    expect(
        await c.readBlob(MediaCacheKey(
            albumId: 'a1',
            mediaId: 'm1',
            epochTag: 0,
            asset: CacheAsset.thumb)),
        isNull);
    expect(
        durable
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.kec')),
        isEmpty);
  });
}
