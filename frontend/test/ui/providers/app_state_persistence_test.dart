import 'package:flutter_test/flutter_test.dart';

import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/ui/providers/app_state.dart';

AlbumModel _album(String id) => AlbumModel(
      id: id,
      nameCt: null,
      createdAt: DateTime.utc(2026, 9, 1),
      updatedAt: DateTime.utc(2026, 9, 1),
    );

void main() {
  late AppState state;
  late List<List<String>> persisted;

  setUp(() {
    state = AppState();
    persisted = [];
    state.attachShelfPersistence(
        (albums) async => persisted.add([for (final a in albums) a.id]));
  });

  test('a server listing is persisted', () async {
    state.setAlbums([_album('a1'), _album('a2')]);
    await Future<void>.delayed(Duration.zero);
    expect(persisted.last, ['a1', 'a2']);
  });

  test('a newly created album is persisted', () async {
    state.setAlbums([_album('a1')]);
    state.prependAlbum(_album('a2'));
    await Future<void>.delayed(Duration.zero);
    expect(persisted.last, ['a2', 'a1']);
  });

  test('a revoked album is persisted as gone', () async {
    state.setAlbums([_album('a1'), _album('a2')]);
    state.removeAlbum('a1');
    await Future<void>.delayed(Duration.zero);
    expect(persisted.last, ['a2']);
  });

  test('persistence never runs two writes at once', () async {
    var inFlight = 0;
    var overlapped = false;
    state.attachShelfPersistence((albums) async {
      inFlight++;
      if (inFlight > 1) overlapped = true;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      inFlight--;
    });

    state.setAlbums([_album('a1')]);
    state.setAlbums([_album('a1'), _album('a2')]);
    state.setAlbums([_album('a3')]);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(overlapped, isFalse,
        reason: 'interleaved writes could persist a stale shelf last');
  });

  test('a photo arriving over realtime is persisted', () async {
    state.setAlbums([_album('a1'), _album('a2')]);
    persisted.clear();

    state.applyMediaAdded('a2', 6);
    await Future<void>.delayed(Duration.zero);

    expect(persisted, isNotEmpty,
        reason: 'cover, generation and shelf order all changed');
    expect(persisted.last, ['a2', 'a1'],
        reason: 'the album moved to the front and that must survive a restart');
  });

  test('a resolved album title is persisted', () async {
    state.setAlbums([_album('a1')]);
    persisted.clear();

    state.applyAlbumNameCt('a1', 'sealed-ct', 'Trip to Hunza');
    await Future<void>.delayed(Duration.zero);

    expect(persisted, isNotEmpty,
        reason: 'else the album reopens offline as the placeholder title');
  });
}
