import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:keepsy/data/storage/media_cache_key.dart';
import 'package:keepsy/data/storage/media_ciphertext_cache.dart';
import 'package:keepsy/e2ee/media_record.dart';

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
      createdAt: DateTime.utc(2026, 6, 3, 12),
    );

MediaCacheKey _fileK(String id, {String album = 'A', int epoch = 0}) =>
    MediaCacheKey(
        albumId: album, mediaId: id, epochTag: epoch, asset: CacheAsset.file);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tmp;
  late MediaCiphertextCache cache;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mcc_');
    cache = await MediaCiphertextCache.open(rootDir: tmp, budgetBytes: 1000);
  });

  tearDown(() async {
    await cache.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('writeRecord then readRecord round-trips', () async {
    final r = _rec('m1');
    await cache.writeRecord(r);
    final got = await cache.readRecord('m1');
    expect(got, isNotNull);
    expect(got!.id, 'm1');
    expect(got.epochTag, 0);
  });

  test('writeBlob then readBlob round-trips', () async {
    await cache.writeRecord(_rec('m1'));
    final cipher = Uint8List.fromList(List.generate(80, (i) => i));
    await cache.writeBlob(_fileK('m1'), cipher);
    final got = await cache.readBlob(_fileK('m1'));
    expect(got, equals(cipher));
  });

  test('eviction by last_access when over budget', () async {
    // budget = 1000, write 4 x 300 byte blobs -> total 1200, evict oldest
    for (var i = 1; i <= 4; i++) {
      await cache.writeRecord(_rec('m$i'));
      await cache.writeBlob(_fileK('m$i'), Uint8List(300));
      await Future.delayed(const Duration(milliseconds: 5));
    }
    final total = await cache.totalBytes();
    expect(total, lessThanOrEqualTo(1000));
    // m1 (oldest) should be gone
    expect(await cache.readBlob(_fileK('m1')), isNull);
    expect(await cache.readBlob(_fileK('m4')), isNotNull);
  });

  test('invalidate drops row + both blob files', () async {
    await cache.writeRecord(_rec('m1'));
    await cache.writeBlob(_fileK('m1'), Uint8List(50));
    await cache.invalidate('m1');
    expect(await cache.readRecord('m1'), isNull);
    expect(await cache.readBlob(_fileK('m1')), isNull);
  });

  test('clearAlbum drops only that album', () async {
    await cache.writeRecord(_rec('m1', album: 'A'));
    await cache.writeBlob(_fileK('m1', album: 'A'), Uint8List(50));
    await cache.writeRecord(_rec('m2', album: 'B'));
    await cache.writeBlob(_fileK('m2', album: 'B'), Uint8List(50));
    await cache.clearAlbum('A');
    expect(await cache.readBlob(_fileK('m1', album: 'A')), isNull);
    expect(await cache.readBlob(_fileK('m2', album: 'B')), isNotNull);
  });

  test('clearAll empties everything', () async {
    await cache.writeRecord(_rec('m1'));
    await cache.writeBlob(_fileK('m1'), Uint8List(50));
    await cache.clearAll();
    expect(await cache.readRecord('m1'), isNull);
    expect(await cache.totalBytes(), 0);
  });

  test('corrupted blob file: readBlob returns null after delete', () async {
    await cache.writeRecord(_rec('m1'));
    await cache.writeBlob(_fileK('m1'), Uint8List(50));
    // simulate corruption: delete the file directly
    final f = File('${tmp.path}/m1.bin');
    if (f.existsSync()) f.deleteSync();
    expect(await cache.readBlob(_fileK('m1')), isNull);
  });
}
