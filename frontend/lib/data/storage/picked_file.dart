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

Future<List<String>> pickerCacheRoots() async {
  final roots = <String>[];
  for (final probe in [getTemporaryDirectory, getApplicationCacheDirectory]) {
    try {
      roots.add((await probe()).path);
    } catch (_) {}
  }
  return roots;
}
