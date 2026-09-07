import 'dart:async';
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

  group('staging', () {
    late Directory staging;
    setUp(() => staging = Directory(p.join(root.path, 'keepsy_picks')));

    test('adopting moves the picker copy out of the shared cache', () async {
      final f = pick('9f2c-uuid');

      final staged = await adoptPickedFile(f.path, staging);

      expect(f.existsSync(), isFalse);
      expect(File(staged).existsSync(), isTrue);
      expect(p.isWithin(staging.path, staged), isTrue);
      expect(File(staged).readAsBytesSync(), [1, 2, 3]);
    });

    test('two picks with the same name do not collide', () async {
      final a = pick('dir-a');
      final b = pick('dir-b');

      final one = await adoptPickedFile(a.path, staging);
      final two = await adoptPickedFile(b.path, staging);

      expect(one, isNot(two));
      expect(File(one).existsSync(), isTrue);
      expect(File(two).existsSync(), isTrue);
    });

    test('a pick that cannot be moved keeps its original path', () async {
      final missing = p.join(root.path, 'gone', 'x.jpg');

      final staged = await adoptPickedFile(missing, staging);

      expect(staged, missing);
    });

    test('a half-finished move leaves no second copy behind', () async {
      final f = pick('locked');
      // Force both rename and copy cleanup to fail
      Process.runSync('chmod', ['a-w', f.parent.path]);
      addTearDown(() => Process.runSync('chmod', ['u+w', f.parent.path]));

      final staged = await adoptPickedFile(f.path, staging);

      expect(staged, f.path, reason: 'the move did not complete');
      expect(f.existsSync(), isTrue);
      final leftovers = staging.existsSync()
          ? staging.listSync().map((e) => e.path).toList()
          : <String>[];
      expect(leftovers, isEmpty,
          reason: 'a copy nothing tracks is unreferenced plaintext');
    });

    test('a sweep clears leftovers from a previous run', () async {
      final f = pick('9f2c-uuid');
      final staged = await adoptPickedFile(f.path, staging);

      await sweepPickerStaging(staging);

      expect(File(staged).existsSync(), isFalse);
      expect(staging.existsSync(), isTrue);
    });

    test('a sweep of a directory that was never used is harmless', () async {
      await sweepPickerStaging(Directory(p.join(root.path, 'absent')));
    });
  });

  group('staging gate', () {
    test('an adoption waits for the startup sweep to finish', () async {
      final staging = Directory(p.join(root.path, 'keepsy_picks'))
        ..createSync(recursive: true);
      final leftover = File(p.join(staging.path, 'stale.jpg'))
        ..writeAsBytesSync([7]);
      final f = pick('9f2c-uuid');

      final gate = Completer<void>();
      var sweeps = 0;
      final gated = PickerStaging(
        () async => staging,
        sweeper: (dir) async {
          sweeps++;
          await gate.future;
          await sweepPickerStaging(dir);
        },
      );

      final adopting = gated.adopt(f.path);
      await pumpEventQueue();
      expect(f.existsSync(), isTrue,
          reason: 'the pick must not move while the sweep is still running');

      gate.complete();
      final staged = await adopting;

      expect(leftover.existsSync(), isFalse);
      expect(File(staged).existsSync(), isTrue);
      expect(sweeps, 1);
    });

    test('the sweep runs once however many picks arrive', () async {
      final staging = Directory(p.join(root.path, 'keepsy_picks'));
      var sweeps = 0;
      final gated = PickerStaging(
        () async => staging,
        sweeper: (dir) async => sweeps++,
      );

      await gated.sweep();
      await gated.adopt(pick('a').path);
      await gated.adopt(pick('b').path);

      expect(sweeps, 1);
    });
  });

  test('empty roots delete nothing', () async {
    final f = pick('9f2c-uuid');

    await discardPickedFile(f.path, const []);
    await discardPickedFile(f.path, const ['']);

    expect(f.existsSync(), isTrue);
  });
}
