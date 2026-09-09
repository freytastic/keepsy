import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/e2ee/media_record.dart';

// Cached album metadata used for local-first rendering
abstract class MediaCatalog {
  Future<List<MediaRecord>> listRecordsForAlbum(String albumId);

  // Missing rows are removed, so records must be a complete server listing
  Future<void> reconcileAlbum(String albumId, List<MediaRecord> records);
}

// Durable shelf metadata for local first rendering
abstract class AlbumCatalog {
  Future<List<AlbumModel>> loadAlbums();

  // Albums must be a complete shelf listing
  Future<void> saveAlbums(List<AlbumModel> albums);

  // Revocation and deletion must remove the durable album entry
  Future<void> dropAlbum(String albumId);
}
