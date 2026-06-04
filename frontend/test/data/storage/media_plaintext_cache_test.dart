import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/storage/media_cache_key.dart';
import 'package:keepsy/data/storage/media_plaintext_cache.dart';

MediaCacheKey _k(String m, {String a = 'A', int e = 0}) =>
    MediaCacheKey(albumId: a, mediaId: m, epochTag: e, asset: CacheAsset.file);

void main() {
  test('put then get returns same bytes', () {
    final c = MediaPlaintextCache(budgetBytes: 1024);
    final b = Uint8List.fromList([1, 2, 3]);
    c.put(_k('m1'), b);
    expect(c.get(_k('m1')), equals(b));
  });

  test('miss returns null', () {
    final c = MediaPlaintextCache(budgetBytes: 1024);
    expect(c.get(_k('nope')), isNull);
  });

  test('LRU eviction when over budget', () {
    final c = MediaPlaintextCache(budgetBytes: 100);
    c.put(_k('m1'), Uint8List(40));
    c.put(_k('m2'), Uint8List(40));
    c.put(_k('m3'), Uint8List(40)); // 120 > 100 -> evict m1
    expect(c.get(_k('m1')), isNull);
    expect(c.get(_k('m2')), isNotNull);
    expect(c.get(_k('m3')), isNotNull);
    expect(c.totalBytes, lessThanOrEqualTo(100));
  });

  test('get marks recently-used (moves to front)', () {
    final c = MediaPlaintextCache(budgetBytes: 100);
    c.put(_k('m1'), Uint8List(40));
    c.put(_k('m2'), Uint8List(40));
    c.get(_k('m1')); // touch m1 -> m2 now oldest
    c.put(_k('m3'), Uint8List(40)); // evict m2
    expect(c.get(_k('m1')), isNotNull);
    expect(c.get(_k('m2')), isNull);
    expect(c.get(_k('m3')), isNotNull);
  });

  test('oversized single value is not inserted', () {
    final c = MediaPlaintextCache(budgetBytes: 100);
    c.put(_k('m1'), Uint8List(200));
    expect(c.get(_k('m1')), isNull);
    expect(c.totalBytes, 0);
  });

  test('clearAlbum drops only that album', () {
    final c = MediaPlaintextCache(budgetBytes: 1024);
    c.put(_k('m1', a: 'A'), Uint8List(10));
    c.put(_k('m2', a: 'B'), Uint8List(10));
    c.clearAlbum('A');
    expect(c.get(_k('m1', a: 'A')), isNull);
    expect(c.get(_k('m2', a: 'B')), isNotNull);
  });

  test('removeByMediaId drops by id ignoring album', () {
    final c = MediaPlaintextCache(budgetBytes: 1024);
    c.put(_k('m1', a: 'A'), Uint8List(10));
    c.put(_k('m1', a: 'B'), Uint8List(10));
    c.removeByMediaId('m1');
    expect(c.get(_k('m1', a: 'A')), isNull);
    expect(c.get(_k('m1', a: 'B')), isNull);
    expect(c.totalBytes, 0);
  });

  test('clearAll empties', () {
    final c = MediaPlaintextCache(budgetBytes: 1024);
    c.put(_k('m1'), Uint8List(10));
    c.clearAll();
    expect(c.count, 0);
    expect(c.totalBytes, 0);
  });
}
