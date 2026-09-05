import 'package:keepsy/e2ee/media_record.dart';

// Cached album metadata used for local-first rendering
abstract class MediaCatalog {
  Future<List<MediaRecord>> listRecordsForAlbum(String albumId);

  // Missing rows are removed, so records must be a complete server listing
  Future<void> reconcileAlbum(String albumId, List<MediaRecord> records);
}
