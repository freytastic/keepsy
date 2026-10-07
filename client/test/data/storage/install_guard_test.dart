import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/data/storage/install_guard.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory support;
  late int wipes;
  late List<String> excluded;

  setUp(() {
    support = Directory.systemTemp.createTempSync('install_guard');
    wipes = 0;
    excluded = [];
  });

  tearDown(() => support.deleteSync(recursive: true));

  Future<void> run({required bool isIOS, Future<void> Function()? wipe}) =>
      prepareInstall(
        isIOS: isIOS,
        supportDir: support,
        wipeKeychain: wipe ?? () async => wipes++,
        excludeFromBackup: (path) async => excluded.add(path),
      );

  File marker() => File(p.join(support.path, kInstallMarkerName));

  test('Android installs are never wiped or marked', () async {
    await run(isIOS: false);
    expect(wipes, 0);
    expect(excluded, isEmpty);
    expect(marker().existsSync(), isFalse);
  });

  test('a fresh iOS install clears the keychain once', () async {
    await run(isIOS: true);
    await run(isIOS: true);
    expect(wipes, 1);
    expect(marker().existsSync(), isTrue);
    expect(excluded, [support.path, support.path]);
  });

  test('a failed wipe leaves no marker so the next launch retries', () async {
    await expectLater(
      run(isIOS: true, wipe: () async => throw StateError('keychain')),
      throwsStateError,
    );
    expect(marker().existsSync(), isFalse);

    await run(isIOS: true);
    expect(wipes, 1);
  });

  test('a failed backup exclusion does not block the wipe', () async {
    await prepareInstall(
      isIOS: true,
      supportDir: support,
      wipeKeychain: () async => wipes++,
      excludeFromBackup: (_) async => throw StateError('channel'),
    );
    expect(wipes, 1);
    expect(marker().existsSync(), isTrue);
  });
}
