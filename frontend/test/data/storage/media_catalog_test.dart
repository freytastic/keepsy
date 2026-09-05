import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/storage/media_cache_key.dart';
import 'package:keepsy/data/storage/media_sealed_cache.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

MediaRecord rec(String id, {String album = 'album-1', int epoch = 0}) =>
    MediaRecord(
      id: id,
      albumId: album,
      uploaderToken: 'tok',
      wrapNonce: Uint8List(12),
      wrapTagCT: Uint8List(48),
      epochTag: epoch,
      blobSize: 100,
      blobSha256: Uint8List(32),
      mediaType: 'photo',
      mimeType: 'image/jpeg',
      createdAt: DateTime.utc(2026, 1, 1),
      thumbWrapNonce: Uint8List(12),
      thumbWrapTagCT: Uint8List(48),
      thumbSize: 20,
      thumbSha256: Uint8List(32),
    );

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory dir;
  late MediaSealedCache cache;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('keepsy_catalog');
    cache = await MediaSealedCache.open(
      rootDir: dir,
      cacheRootKey: Uint8List(32),
    );
  });

  tearDown(() async {
    await cache.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  List<String> ids(List<MediaRecord> rs) => [for (final r in rs) r.id];

  test('reconcile preserves and updates server order', () async {
    await cache.reconcileAlbum('album-1', [rec('c'), rec('a'), rec('b')]);
    expect(ids(await cache.listRecordsForAlbum('album-1')), ['c', 'a', 'b']);
    await cache.reconcileAlbum('album-1', [rec('b'), rec('a')]);
    expect(ids(await cache.listRecordsForAlbum('album-1')), ['b', 'a']);
  });

  test('authoritative reconciliation removes rows and cached blobs', () async {
    final k = MediaCacheKey(
        albumId: 'album-1', mediaId: 'a', epochTag: 0, asset: CacheAsset.thumb);
    await cache.reconcileAlbum('album-1', [rec('a'), rec('b')]);
    await cache.writeBlob(k, Uint8List.fromList([1, 2, 3]));
    await cache.reconcileAlbum('album-1', [rec('b')]);

    expect(await cache.readBlob(k), isNull);
    expect(ids(await cache.listRecordsForAlbum('album-1')), ['b']);
  });

  test('reconcile never touches another album', () async {
    await cache.reconcileAlbum('album-1', [rec('a')]);
    await cache.reconcileAlbum('album-2', [rec('z', album: 'album-2')]);
    await cache.reconcileAlbum('album-1', <MediaRecord>[]);

    expect(ids(await cache.listRecordsForAlbum('album-2')), ['z']);
  });

  test('new arrivals stay newest first before reconciliation', () async {
    await cache.reconcileAlbum('album-1', [rec('a')]);
    await cache.writeRecord(rec('n1'));
    await cache.writeRecord(rec('n2'));

    expect(ids(await cache.listRecordsForAlbum('album-1')), ['n2', 'n1', 'a']);
  });

  test('a bytes only placeholder never surfaces as a record', () async {
    await cache.writeBlob(
      MediaCacheKey(
          albumId: 'album-1',
          mediaId: 'ghost',
          epochTag: 0,
          asset: CacheAsset.thumb),
      Uint8List.fromList([9]),
    );

    expect(await cache.listRecordsForAlbum('album-1'), isEmpty);
  });

  test('records survive reopening with decryption metadata intact', () async {
    await cache.reconcileAlbum('album-1', [rec('a', epoch: 7), rec('b')]);
    await cache.close();

    cache =
        await MediaSealedCache.open(rootDir: dir, cacheRootKey: Uint8List(32));

    final records = await cache.listRecordsForAlbum('album-1');
    expect(ids(records), ['a', 'b']);
    final back = records.first;
    expect(back.id, 'a');
    expect(back.epochTag, 7);
    expect(back.wrapTagCT.length, 48);
    expect(back.hasThumb, isTrue);
    expect(back.thumbSize, 20);
  });

  test('a preview filling an existing placeholder still leads the album',
      () async {
    await cache.reconcileAlbum('album-1', [rec('a'), rec('b')]);
    await cache.writeBlob(
      const MediaCacheKey(
        albumId: 'album-1',
        mediaId: 'fresh',
        epochTag: 0,
        asset: CacheAsset.thumb,
      ),
      Uint8List(16),
    );

    await cache.writeRecordIfAbsent(rec('fresh'));

    expect(
        ids(await cache.listRecordsForAlbum('album-1')), ['fresh', 'a', 'b']);
  });

  test('eviction over budget keeps catalog rows that hold no bytes', () async {
    await cache.close();
    cache = await MediaSealedCache.open(
      rootDir: dir,
      cacheRootKey: Uint8List(32),
      budgetBytes: 512,
    );

    await cache.reconcileAlbum('album-1', [rec('a'), rec('b')]);
    await cache.reconcileAlbum('album-2', [rec('z', album: 'album-2')]);

    await cache.writeBlob(
      const MediaCacheKey(
        albumId: 'album-1',
        mediaId: 'a',
        epochTag: 0,
        asset: CacheAsset.file,
      ),
      Uint8List(4096),
    );

    expect(ids(await cache.listRecordsForAlbum('album-1')), ['a', 'b']);
    expect(ids(await cache.listRecordsForAlbum('album-2')), ['z']);
  });
}
