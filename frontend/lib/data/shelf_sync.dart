import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/storage/media_catalog.dart';

// Apply the durable shelf before refreshing from the server
// Failed refreshes keep local state and only a valid listing may shrink it
Future<void> loadShelf({
  required AlbumCatalog catalog,
  required Future<List<AlbumModel>?> Function() fetch,
  required void Function(List<AlbumModel>) apply,
}) async {
  try {
    final local = await catalog.loadAlbums();
    if (local.isNotEmpty) apply(local);
  } catch (_) {
    // Keep refreshing if the local catalog is unreadable
  }

  List<AlbumModel>? fresh;
  try {
    fresh = await fetch();
  } catch (_) {
    return;
  }
  if (fresh == null) return;

  // AppState is the only writer so merged realtime state wins
  apply(fresh);
}
