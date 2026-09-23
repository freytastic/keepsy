import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/storage/own_avatar_store.dart';
import 'package:keepsy/domain/avatar/avatar_publisher.dart';

Uint8List _key(int b) => Uint8List.fromList(List<int>.filled(32, b));
final _jpeg = Uint8List.fromList([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('ownavatar'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File file() => File('${dir.path}/avatar.kec');
  Future<OwnAvatarStore> open([int key = 1]) =>
      OwnAvatarStore.open(file: file(), cacheRootKey: _key(key));

  test('a fresh install knows nothing', () async {
    final s = await open();
    expect(s.state, OwnAvatarState.unknown);
    expect(s.jpeg, isNull);
  });

  test('a photo and its published copies survive a restart', () async {
    final s = await open();
    await s.set(_jpeg);
    await s.markPublished('album-1', 'avatar-1', s.revision!);

    final again = await open();
    expect(again.state, OwnAvatarState.set);
    expect(again.jpeg, _jpeg);
    expect(again.revision, s.revision);
    expect(again.publishedTo('album-1'), 'avatar-1');
  });

  test('a new photo makes every album copy stale', () async {
    final s = await open();
    await s.set(_jpeg);
    final first = s.revision!;
    await s.markPublished('album-1', 'avatar-1', first);
    await s.set(Uint8List.fromList([9, 9]));

    expect(s.revision, isNot(first));
    expect(s.publishedTo('album-1'), isNull);
    // An upload of the old photo finishing late must not count
    await s.markPublished('album-1', 'avatar-old', first);
    expect(s.publishedTo('album-1'), isNull);
  });

  test('removal is remembered as removal', () async {
    final s = await open();
    await s.set(_jpeg);
    await s.remove();
    final again = await open();
    expect(again.state, OwnAvatarState.removed);
    expect(again.jpeg, isNull);
  });

  test('an unreadable file never reads as a removal', () async {
    final s = await open(1);
    await s.remove();
    expect((await open(2)).state, OwnAvatarState.unknown);
  });

  test('stores nothing readable on disk', () async {
    final s = await open();
    await s.set(Uint8List.fromList('FACE-BYTES'.codeUnits));
    final raw = String.fromCharCodes(file().readAsBytesSync());
    expect(raw.contains('FACE'), isFalse);
    expect(raw.contains('published'), isFalse);
  });

  test('wipe deletes the file and forgets everything', () async {
    final s = await open();
    await s.set(_jpeg);
    await s.wipe();
    expect(file().existsSync(), isFalse);
    expect(s.state, OwnAvatarState.unknown);
  });
}
