import 'dart:convert';
import 'dart:io';

import 'package:keepsy/domain/account/account_deletion.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const kDeletionMarkerName = 'keepsy_deletion_pending.json';

// Holds only a random receipt and album ids already on the server, so it is
// stored plain. It must survive the wipe that empties its own directory
class DeletionMarkerFile implements DeletionMarkerStore {
  final File file;
  DeletionMarkerFile(this.file);

  static Future<DeletionMarkerFile> open() async =>
      DeletionMarkerFile(File(p.join(
          (await getApplicationSupportDirectory()).path, kDeletionMarkerName)));

  @override
  Future<PendingDeletion?> read() async {
    if (!await file.exists()) return null;
    return PendingDeletion.tryParse(jsonDecode(await file.readAsString()));
  }

  @override
  Future<void> write(PendingDeletion pending) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(pending.toJson()), flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }
}
