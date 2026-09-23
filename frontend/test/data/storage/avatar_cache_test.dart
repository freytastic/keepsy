import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/models/avatar_ref.dart';
import 'package:keepsy/data/storage/avatar_cache.dart';

Uint8List _key(int b) => Uint8List.fromList(List<int>.filled(32, b));

AvatarRef _ref(String id) => AvatarRef(
    avatarId: id,
    blobSize: 10,
    blobSha256: Uint8List(32),
    keyCt: Uint8List(65));

void main() {
  late Directory dir;
  late List<String> fetched;
  late Map<String, Uint8List?> served;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('avatarcache');
    fetched = [];
    served = {};
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<AvatarCache> open() => AvatarCache.open(
        root: dir,
        cacheRootKey: _key(3),
        fetch: (albumId, token, ref) async {
          fetched.add(ref.avatarId);
          return served[ref.avatarId];
        },
      );

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('loads once, notifies, and serves from memory', () async {
    served['v1'] = Uint8List.fromList('FACE-ONE'.codeUnits);
    final c = await open();
    var notified = 0;
    c.addListener(() => notified++);

    c.ensure('album', 'tok', _ref('v1'));
    c.ensure('album', 'tok', _ref('v1'));
    await settle();

    expect(c.peek('album', 'tok', 'v1'), served['v1']);
    expect(fetched, ['v1']);
    expect(notified, 1);
  });

  test('a restart reads the sealed copy instead of downloading', () async {
    served['v1'] = Uint8List.fromList('FACE-ONE'.codeUnits);
    final first = await open();
    first.ensure('album', 'tok', _ref('v1'));
    await settle();

    final second = await open();
    second.ensure('album', 'tok', _ref('v1'));
    await settle();
    expect(second.peek('album', 'tok', 'v1'), served['v1']);
    expect(fetched, ['v1']);
  });

  test('a new avatar id replaces the old one', () async {
    served['v1'] = Uint8List.fromList([1]);
    served['v2'] = Uint8List.fromList([2]);
    final c = await open();
    c.ensure('album', 'tok', _ref('v1'));
    await settle();
    c.ensure('album', 'tok', _ref('v2'));
    await settle();

    expect(c.peek('album', 'tok', 'v1'), isNull);
    expect(c.peek('album', 'tok', 'v2'), [2]);
    expect(fetched, ['v1', 'v2']);
  });

  test('a failed avatar is not retried straight away', () async {
    final c = await open();
    c.ensure('album', 'tok', _ref('bad'));
    await settle();
    c.ensure('album', 'tok', _ref('bad'));
    await settle();
    expect(fetched, ['bad']);
    expect(c.peek('album', 'tok', 'bad'), isNull);
  });

  test('nothing readable reaches the disk', () async {
    served['v1'] = Uint8List.fromList('FACE-ONE'.codeUnits);
    final c = await open();
    c.ensure('album-secret', 'tok-secret', _ref('v1'));
    await settle();

    final files = dir.listSync(recursive: true).whereType<File>().toList();
    expect(files, hasLength(1));
    for (final f in files) {
      expect(f.path.contains('album-secret'), isFalse);
      expect(f.path.contains('tok-secret'), isFalse);
      expect(
          String.fromCharCodes(f.readAsBytesSync()).contains('FACE'), isFalse);
    }
  });

  test('clearing an album drops its faces and files only', () async {
    served['v1'] = Uint8List.fromList([1]);
    served['v2'] = Uint8List.fromList([2]);
    final c = await open();
    c.ensure('gone', 'tok', _ref('v1'));
    c.ensure('kept', 'tok', _ref('v2'));
    await settle();

    await c.clearAlbum('gone');
    expect(await c.holdsAlbum('gone'), isFalse);
    expect(c.peek('gone', 'tok', 'v1'), isNull);
    expect(await c.holdsAlbum('kept'), isTrue);
    expect(c.peek('kept', 'tok', 'v2'), [2]);
  });

  test('clearAll empties memory and disk', () async {
    served['v1'] = Uint8List.fromList([1]);
    final c = await open();
    c.ensure('album', 'tok', _ref('v1'));
    await settle();
    await c.clearAll();
    expect(c.peek('album', 'tok', 'v1'), isNull);
    expect(dir.existsSync(), isFalse);
  });
}
