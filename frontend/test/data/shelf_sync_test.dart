import 'package:flutter_test/flutter_test.dart';

import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/shelf_sync.dart';
import 'package:keepsy/data/storage/media_catalog.dart';

AlbumModel _album(String id) => AlbumModel(
      id: id,
      nameCt: null,
      createdAt: DateTime.utc(2026, 9, 1),
      updatedAt: DateTime.utc(2026, 9, 1),
    );

class _FakeCatalog implements AlbumCatalog {
  List<AlbumModel> stored;
  int saves = 0;
  _FakeCatalog(this.stored);

  @override
  Future<List<AlbumModel>> loadAlbums() async => stored;

  @override
  Future<void> dropAlbum(String albumId) async {
    stored = [
      for (final a in stored)
        if (a.id != albumId) a
    ];
  }

  @override
  Future<void> saveAlbums(List<AlbumModel> albums) async {
    stored = albums;
    saves++;
  }
}

void main() {
  test('a shelf saved earlier renders before the network answers', () async {
    final catalog = _FakeCatalog([_album('a1')]);
    final applied = <List<String>>[];

    await loadShelf(
      catalog: catalog,
      fetch: () async => [_album('a1'), _album('a2')],
      apply: (albums) => applied.add([for (final a in albums) a.id]),
    );

    expect(applied.first, ['a1'], reason: 'local shelf paints first');
    expect(applied.last, ['a1', 'a2'], reason: 'server listing wins after');
    expect(catalog.saves, 0,
        reason: 'apply is the single writer : loadShelf must not persist too');
  });

  test('an unreachable server leaves the local shelf standing', () async {
    final catalog = _FakeCatalog([_album('a1')]);
    final applied = <List<String>>[];

    await loadShelf(
      catalog: catalog,
      fetch: () async => throw Exception('connection refused'),
      apply: (albums) => applied.add([for (final a in albums) a.id]),
    );

    expect(
        applied,
        [
          ['a1']
        ],
        reason: 'the shelf must never be blanked by a failed refresh');
    expect(catalog.saves, 0, reason: 'nothing authoritative arrived to save');
  });

  test('a null listing is not treated as an empty shelf', () async {
    final catalog = _FakeCatalog([_album('a1')]);
    final applied = <List<String>>[];

    await loadShelf(
      catalog: catalog,
      fetch: () async => null,
      apply: (albums) => applied.add([for (final a in albums) a.id]),
    );

    expect(applied, [
      ['a1']
    ]);
    expect(catalog.saves, 0);
  });

  test('an authoritative empty listing does clear the shelf', () async {
    final catalog = _FakeCatalog([_album('a1')]);
    final applied = <List<String>>[];

    await loadShelf(
      catalog: catalog,
      fetch: () async => <AlbumModel>[],
      apply: (albums) => applied.add([for (final a in albums) a.id]),
    );

    expect(applied.last, isEmpty);
    expect(catalog.saves, 0);
  });
}
