import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// Deletes plaintext picker copies only within app cache roots
Future<void> discardPickedFile(String path, List<String> roots) async {
  final owned = roots.where((r) => r.isNotEmpty).toList();
  if (!owned.any((r) => p.isWithin(r, path))) return;
  try {
    final file = File(path);
    if (file.existsSync()) await file.delete();
    final dir = file.parent;
    if (dir.existsSync() &&
        !owned.any((r) => p.equals(r, dir.path)) &&
        await dir.list().isEmpty) {
      await dir.delete();
    }
  } catch (_) {
    // Cleanup is best effort
  }
}

// Moves picker plaintext into a staging directory safe to sweep
Future<String> adoptPickedFile(String path, Directory staging) async {
  String? target;
  try {
    final source = File(path);
    if (!source.existsSync()) return path;
    if (!staging.existsSync()) staging.createSync(recursive: true);
    target = p.join(staging.path,
        '${DateTime.now().microsecondsSinceEpoch}_${p.basename(path)}');
    try {
      await source.rename(target);
    } on FileSystemException {
      await source.copy(target);
      await source.delete();
    }
    return target;
  } catch (_) {
    // Delete any untracked plaintext copy
    if (target != null) {
      try {
        await File(target).delete();
      } catch (_) {}
    }
    return path;
  }
}

// Clears picks left by a previous run
Future<void> sweepPickerStaging(Directory staging) async {
  try {
    if (!staging.existsSync()) return;
    await for (final entry in staging.list()) {
      try {
        await entry.delete(recursive: true);
      } catch (_) {}
    }
  } catch (_) {}
}

Future<Directory> pickerStagingDir() async => Directory(
    p.join((await getApplicationCacheDirectory()).path, 'keepsy_picks'));

// Makes adoption wait for the startup sweep
class PickerStaging {
  final Future<Directory> Function() _dir;
  final Future<void> Function(Directory) _sweeper;
  Future<void>? _swept;
  Directory? _cached;

  PickerStaging(
    Future<Directory> Function() dir, {
    Future<void> Function(Directory)? sweeper,
  })  : _dir = dir,
        _sweeper = sweeper ?? sweepPickerStaging;

  Future<Directory> _resolve() async => _cached ??= await _dir();

  Future<void> sweep() => _swept ??= _resolve().then(_sweeper);

  Future<String> adopt(String path) async {
    await sweep();
    return adoptPickedFile(path, await _resolve());
  }
}

Future<List<String>> pickerCacheRoots() async {
  final roots = <String>[];
  for (final probe in [getTemporaryDirectory, getApplicationCacheDirectory]) {
    try {
      roots.add((await probe()).path);
    } catch (_) {}
  }
  return roots;
}
