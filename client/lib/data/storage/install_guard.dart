import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

const kInstallMarkerName = 'miuchio_installed';

const MethodChannel _storageChannel = MethodChannel('miuchio/storage');

// iOS can retain Keychain items after uninstall, so a missing file marker
// triggers a wipe before any keys or credentials are read
// Retain the marker during in-app erasure so the next launch preserves any
// new sign-in made afterward
Future<void> prepareInstall({
  required bool isIOS,
  required Directory supportDir,
  required Future<void> Function() wipeKeychain,
  Future<void> Function(String path)? excludeFromBackup,
}) async {
  if (!isIOS) return;
  await supportDir.create(recursive: true);
  try {
    await (excludeFromBackup ?? _excludeFromBackup)(supportDir.path);
  } catch (_) {
    // Retry backup exclusion on the next launch
  }
  final marker = File(p.join(supportDir.path, kInstallMarkerName));
  if (await marker.exists()) return;
  await wipeKeychain();
  await marker.writeAsString('', flush: true);
}

Future<void> _excludeFromBackup(String path) =>
    _storageChannel.invokeMethod<void>('excludeFromBackup', {'path': path});
