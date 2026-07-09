import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/storage/name_cache.dart';

Uint8List _key(int b) => Uint8List.fromList(List<int>.filled(32, b));

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('namecache'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File nameFile() => File('${dir.path}/names.kec');

  test('get returns a value only on a fingerprint match', () async {
    final c = await NameCache.open(file: nameFile(), cacheRootKey: _key(1));
    c.put(NameCache.albumKey('alb'), 'Ski Trip', 'ct-v1');
    expect(c.get(NameCache.albumKey('alb'), 'ct-v1'), 'Ski Trip');
    // fingerprint changed (rename) -> miss
    expect(c.get(NameCache.albumKey('alb'), 'ct-v2'), isNull);
    // unknown key -> miss
    expect(c.get(NameCache.albumKey('other'), 'ct-v1'), isNull);
  });

  test('persists across reopen with the same key', () async {
    final c1 = await NameCache.open(file: nameFile(), cacheRootKey: _key(7));
    c1.put(NameCache.memberKey('alb', 'tokA'), 'Alice', 'ctA');
    c1.put(NameCache.albumKey('alb'), 'Beach', 'ctAlb');
    await c1.flush();

    final c2 = await NameCache.open(file: nameFile(), cacheRootKey: _key(7));
    expect(c2.get(NameCache.memberKey('alb', 'tokA'), 'ctA'), 'Alice');
    expect(c2.get(NameCache.albumKey('alb'), 'ctAlb'), 'Beach');
  });

  test('a different cache key yields an empty cache (self-heal, no crash)',
      () async {
    final c1 = await NameCache.open(file: nameFile(), cacheRootKey: _key(7));
    c1.put(NameCache.albumKey('alb'), 'Secret', 'ct');
    await c1.flush();

    final c2 = await NameCache.open(file: nameFile(), cacheRootKey: _key(9));
    expect(c2.get(NameCache.albumKey('alb'), 'ct'), isNull);
  });

  test('clear empties memory and deletes the file', () async {
    final f = nameFile();
    final c = await NameCache.open(file: f, cacheRootKey: _key(1));
    c.put(NameCache.albumKey('alb'), 'Title', 'ct');
    await c.flush();
    expect(f.existsSync(), isTrue);

    await c.clear();
    expect(c.get(NameCache.albumKey('alb'), 'ct'), isNull);
    expect(f.existsSync(), isFalse);
  });

  test('missing file opens empty', () async {
    final c = await NameCache.open(file: nameFile(), cacheRootKey: _key(1));
    expect(c.get(NameCache.albumKey('alb'), 'ct'), isNull);
  });

  test('clearAlbum durably drops that album, keeps other albums', () async {
    final f = nameFile();
    final c = await NameCache.open(file: f, cacheRootKey: _key(1));
    c.put(NameCache.albumKey('A'), 'AlbumA', 'ctA');
    c.put(NameCache.memberKey('A', 'tok1'), 'Alice', 'ct1');
    c.put(NameCache.memberKey('A', 'tok2'), 'Bob', 'ct2');
    c.put(NameCache.albumKey('B'), 'AlbumB', 'ctB');
    c.put(NameCache.memberKey('B', 'tok3'), 'Carol', 'ct3');

    await c.clearAlbum('A');

    // in memory
    expect(c.get(NameCache.albumKey('A'), 'ctA'), isNull);
    expect(c.get(NameCache.memberKey('A', 'tok1'), 'ct1'), isNull);
    expect(c.get(NameCache.albumKey('B'), 'ctB'), 'AlbumB');

    // durable : a fresh open from disk must not see album A's names
    final c2 = await NameCache.open(file: f, cacheRootKey: _key(1));
    expect(c2.get(NameCache.albumKey('A'), 'ctA'), isNull);
    expect(c2.get(NameCache.memberKey('A', 'tok1'), 'ct1'), isNull);
    expect(c2.get(NameCache.memberKey('A', 'tok2'), 'ct2'), isNull);
    expect(c2.get(NameCache.albumKey('B'), 'ctB'), 'AlbumB');
    expect(c2.get(NameCache.memberKey('B', 'tok3'), 'ct3'), 'Carol');
  });

  test('clear wins a concurrent in-flight flush (no file left behind)',
      () async {
    final f = nameFile();
    final c = await NameCache.open(file: f, cacheRootKey: _key(1));
    c.put(NameCache.albumKey('A'), 'Secret', 'ct');
    final flushing = c.flush(); // starts sealing/writing
    await c.clear(); // must win the race
    await flushing; // let the (now-superseded) write settle
    expect(f.existsSync(), isFalse);
    expect(c.get(NameCache.albumKey('A'), 'ct'), isNull);
  });
}
