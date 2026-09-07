import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/storage/picked_file.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('picked_test'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File pick(String dirName, {String name = 'IMG_0001.jpg'}) {
    final dir = Directory(p.join(root.path, dirName))..createSync();
    return File(p.join(dir.path, name))..writeAsBytesSync([1, 2, 3]);
  }

  test('deletes the picked copy and its now empty wrapper directory', () async {
    final f = pick('9f2c-uuid');

    await discardPickedFile(f.path, [root.path]);

    expect(f.existsSync(), isFalse);
    expect(f.parent.existsSync(), isFalse);
  });

  test('leaves a wrapper directory that still holds other files', () async {
    final f = pick('9f2c-uuid');
    final sibling = File(p.join(f.parent.path, 'other.jpg'))
      ..writeAsBytesSync([9]);

    await discardPickedFile(f.path, [root.path]);

    expect(f.existsSync(), isFalse);
    expect(sibling.existsSync(), isTrue);
  });

  test('never deletes a path outside the allowed roots', () async {
    final outside = Directory.systemTemp.createTempSync('picked_outside');
    addTearDown(() => outside.deleteSync(recursive: true));
    final f = File(p.join(outside.path, 'gallery_original.jpg'))
      ..writeAsBytesSync([1]);

    await discardPickedFile(f.path, [root.path]);

    expect(f.existsSync(), isTrue,
        reason: 'a path we did not write must never be deleted');
  });

  test('never deletes a root itself', () async {
    final f = File(p.join(root.path, 'loose.jpg'))..writeAsBytesSync([1]);

    await discardPickedFile(f.path, [root.path]);

    expect(f.existsSync(), isFalse);
    expect(root.existsSync(), isTrue);
  });

  test('a missing file is not an error', () async {
    await discardPickedFile(p.join(root.path, 'gone', 'x.jpg'), [root.path]);
  });

  test('empty roots delete nothing', () async {
    final f = pick('9f2c-uuid');

    await discardPickedFile(f.path, const []);
    await discardPickedFile(f.path, const ['']);

    expect(f.existsSync(), isTrue);
  });
}
