import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:keepsy/data/storage/media_cache_key.dart';
import 'package:keepsy/data/storage/media_sealed_cache.dart';
import 'package:keepsy/e2ee/media_record.dart';

Uint8List _key([int fill = 0x11]) =>
    Uint8List.fromList(List<int>.filled(32, fill));

MediaRecord _rec(String id,
        {String album = 'A', int epoch = 0, int blobSize = 100}) =>
    MediaRecord(
      id: id,
      albumId: album,
      uploaderToken: 'tok',
      wrapNonce: Uint8List(12),
      wrapTagCT: Uint8List(48),
      epochTag: epoch,
      blobSize: blobSize,
      blobSha256: Uint8List(32),
      mediaType: 'photo',
      mimeType: 'image/jpeg',
      createdAt: DateTime.utc(2026, 6, 7, 12),
    );

MediaCacheKey _fileK(String id, {String album = 'A', int epoch = 0}) =>
    MediaCacheKey(
        albumId: album, mediaId: id, epochTag: epoch, asset: CacheAsset.file);

Uint8List _bytes(int n) =>
    Uint8List.fromList(List.generate(n, (i) => i & 0xFF));

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tmp;
  late MediaSealedCache cache;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('msc_');
    cache = await MediaSealedCache.open(
        rootDir: tmp, cacheRootKey: _key(), budgetBytes: 1000);
  });

  tearDown(() async {
    await cache.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('writeBlob then readBlob round-trips plaintext', () async {
    await cache.writeRecord(_rec('m1'));
    final pt = _bytes(80);
    await cache.writeBlob(_fileK('m1'), pt);
    expect(await cache.readBlob(_fileK('m1')), equals(pt));
  });

  test('on-disk file is sealed, not the plaintext', () async {
    await cache.writeRecord(_rec('m1'));
    final pt = _bytes(80);
    await cache.writeBlob(_fileK('m1'), pt);
    final raw = await File('${tmp.path}/m1.kec').readAsBytes();
    expect(raw, isNot(equals(pt)));
    // VER(1) + NONCE(12) + TAG(16) header precedes the ciphertext
    expect(raw.length, greaterThan(pt.length));
  });

  test('wrong cache_root_key fails auth and reads as a miss', () async {
    await cache.writeRecord(_rec('m1'));
    await cache.writeBlob(_fileK('m1'), _bytes(80));
    await cache.close();

    final other = await MediaSealedCache.open(
        rootDir: tmp, cacheRootKey: _key(0x22), budgetBytes: 1000);
    expect(await other.readBlob(_fileK('m1')), isNull);
    await other.close();
    // reopen with the original key : the auth-failed file was purged
    cache = await MediaSealedCache.open(
        rootDir: tmp, cacheRootKey: _key(), budgetBytes: 1000);
    expect(await cache.readBlob(_fileK('m1')), isNull);
  });

  test('corrupted file reads as a miss and is purged', () async {
    await cache.writeRecord(_rec('m1'));
    await cache.writeBlob(_fileK('m1'), _bytes(80));
    final f = File('${tmp.path}/m1.kec');
    final raw = await f.readAsBytes();
    raw[raw.length - 1] ^= 0xFF; // flip a tag byte
    await f.writeAsBytes(raw, flush: true);
    expect(await cache.readBlob(_fileK('m1')), isNull);
    expect(f.existsSync(), isFalse);
  });

  test('eviction by last_access when over budget', () async {
    for (var i = 1; i <= 4; i++) {
      await cache.writeRecord(_rec('m$i'));
      await cache.writeBlob(_fileK('m$i'), _bytes(300));
      await Future.delayed(const Duration(milliseconds: 5));
    }
    expect(await cache.totalBytes(), lessThanOrEqualTo(1000));
    expect(await cache.readBlob(_fileK('m1')), isNull);
    expect(await cache.readBlob(_fileK('m4')), isNotNull);
  });

  test('invalidate drops row + blob file', () async {
    await cache.writeRecord(_rec('m1'));
    await cache.writeBlob(_fileK('m1'), _bytes(50));
    await cache.invalidate('m1');
    expect(await cache.readRecord('m1'), isNull);
    expect(File('${tmp.path}/m1.kec').existsSync(), isFalse);
  });

  test('clearAlbum drops only that album', () async {
    await cache.writeRecord(_rec('m1', album: 'A'));
    await cache.writeBlob(_fileK('m1', album: 'A'), _bytes(50));
    await cache.writeRecord(_rec('m2', album: 'B'));
    await cache.writeBlob(_fileK('m2', album: 'B'), _bytes(50));
    await cache.clearAlbum('A');
    expect(await cache.readBlob(_fileK('m1', album: 'A')), isNull);
    expect(await cache.readBlob(_fileK('m2', album: 'B')), isNotNull);
  });

  test('clearAll empties everything', () async {
    await cache.writeRecord(_rec('m1'));
    await cache.writeBlob(_fileK('m1'), _bytes(50));
    await cache.clearAll();
    expect(await cache.readRecord('m1'), isNull);
    expect(await cache.totalBytes(), 0);
  });

  test('migration wipes legacy .bin blobs on first open', () async {
    final fresh = Directory.systemTemp.createTempSync('msc_mig_');
    File('${fresh.path}/old.bin').writeAsBytesSync(_bytes(40));
    File('${fresh.path}/old.thumb.bin').writeAsBytesSync(_bytes(20));
    final c = await MediaSealedCache.open(
        rootDir: fresh, cacheRootKey: _key(), budgetBytes: 1000);
    expect(File('${fresh.path}/old.bin').existsSync(), isFalse);
    expect(File('${fresh.path}/old.thumb.bin').existsSync(), isFalse);
    await c.close();
    fresh.deleteSync(recursive: true);
  });
  group('cover pinning', () {
    MediaCacheKey thumbK(String id, {String album = 'A'}) => MediaCacheKey(
        albumId: album, mediaId: id, epochTag: 0, asset: CacheAsset.thumb);

    test('eviction drops blobs before any thumb', () async {
      for (final id in ['m1', 'm2']) {
        await cache.writeRecord(_rec(id));
        await cache.writeBlob(thumbK(id), _bytes(60));
        await cache.writeBlob(_fileK(id), _bytes(600));
      }
      expect(await cache.readBlob(_fileK('m1')), isNull);
      expect(await cache.readBlob(thumbK('m1')), isNotNull);
      expect(await cache.readBlob(thumbK('m2')), isNotNull);
    });

    test('a pinned cover survives a sweep that evicts an unpinned one',
        () async {
      await cache.setCovers('A', ['m1']);
      for (final id in ['m1', 'm2', 'm3']) {
        await cache.writeRecord(_rec(id));
        await cache.writeBlob(thumbK(id), _bytes(400));
      }

      expect(await cache.readBlob(thumbK('m1')), isNotNull,
          reason: 'pinned cover must survive');
      expect(await cache.readBlob(thumbK('m2')), isNull,
          reason: 'oldest unpinned thumb is the one that goes');
      expect(await cache.readBlob(thumbK('m3')), isNotNull);
    });

    test('cover refs do not outlive the media they point at', () async {
      await cache.writeRecord(_rec('m1'));
      await cache.setCovers('A', ['m1']);
      await cache.invalidate('m1');
      expect(await cache.coversFor('A'), isEmpty);
    });

    test('clearAlbum drops that album covers', () async {
      await cache.writeRecord(_rec('m1'));
      await cache.setCovers('A', ['m1']);
      await cache.clearAlbum('A');
      expect(await cache.coversFor('A'), isEmpty);
    });

    test('setCovers replaces the previous three', () async {
      await cache.setCovers('A', ['m1', 'm2', 'm3']);
      await cache.setCovers('A', ['m4']);
      expect(await cache.coversFor('A'), ['m4']);
    });
  });

  group('record upserts', () {
    MediaCacheKey thumbK(String id) => MediaCacheKey(
        albumId: 'A', mediaId: id, epochTag: 0, asset: CacheAsset.thumb);

    test('rewriting a record keeps its byte accounting', () async {
      await cache.writeRecord(_rec('m1'));
      await cache.writeBlob(thumbK('m1'), _bytes(120));
      final counted = await cache.totalBytes();
      expect(counted, greaterThan(0));

      await cache.writeRecord(_rec('m1', blobSize: 900));

      expect(await cache.totalBytes(), counted,
          reason: 'a REPLACE would zero the columns and orphan the file');
      expect(await cache.readBlob(thumbK('m1')), isNotNull);
    });

    test('a preview record never overwrites a full one', () async {
      await cache.writeRecord(_rec('m1', blobSize: 900));
      await cache.writeRecordIfAbsent(_rec('m1', blobSize: 0));
      expect((await cache.readRecord('m1'))!.blobSize, 900);
    });

    test('a preview record fills in a bytes-only placeholder', () async {
      await cache.writeBlob(thumbK('m1'), _bytes(64));
      expect(await cache.readRecord('m1'), isNull);

      await cache.writeRecordIfAbsent(_rec('m1'));
      expect((await cache.readRecord('m1'))?.id, 'm1');
      expect(await cache.readBlob(thumbK('m1')), isNotNull);
    });
  });
}
