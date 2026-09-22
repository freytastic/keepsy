import 'package:flutter_test/flutter_test.dart';

import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/ui/providers/app_state.dart';

AlbumModel _album(String id) => AlbumModel(
      id: id,
      nameCt: null,
      createdAt: DateTime.utc(2026, 9, 1),
      updatedAt: DateTime.utc(2026, 9, 1),
    );

class _Albums extends AlbumService {
  final List<AlbumModel>? listing;
  _Albums(this.listing);
  @override
  Future<List<AlbumModel>?> getMyAlbums() async => listing;
  @override
  Future<AlbumModel?> getAlbum(String id) async => _album(id);
}

void main() {
  late AppState state;
  late List<List<String>> heard;

  setUp(() {
    state = AppState();
    heard = [];
    // The listener reads app state, so it must see the listing already applied
    state.attachListingApplied(
        () => heard.add([for (final a in state.albums) a.id]));
  });

  test('a server listing is announced after it is applied', () {
    state.applyListing([_album('a1'), _album('a2')]);
    expect(heard, [
      ['a1', 'a2'],
    ]);
  });

  // A local restore can be missing albums, which would read as everyone
  // leaving
  test('a local restore is not announced', () {
    state.setAlbums([_album('a1')]);
    expect(heard, isEmpty);
  });

  test('the listing fetched after a join is announced', () async {
    await state.refreshAlbumOnJoin('a2', _Albums([_album('a1'), _album('a2')]));
    expect(heard, [
      ['a1', 'a2'],
    ]);
  });

  // The single album fallback carries no summary and is not a whole listing
  test('the single album fallback after a join is not announced', () async {
    await state.refreshAlbumOnJoin('a2', _Albums(null));
    expect(state.albums.map((a) => a.id), ['a2']);
    expect(heard, isEmpty);
  });
}
