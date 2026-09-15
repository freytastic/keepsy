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
  test('albums missing from a listing are handed off for a probe', () {
    final vanished = <String>[];
    final s = AppState(summaryDebounce: Duration.zero)
      ..attachAlbumsVanished(vanished.addAll)
      ..setAlbums([_album('a1'), _album('a2')]);
    expect(vanished, isEmpty);

    s.setAlbums([_album('a2')]);
    expect(vanished, ['a1']);
  });

  test('a deleted album is told apart from a removal', () {
    final s = AppState()..markAlbumDeleted('a1');
    expect(s.wasDeleted('a1'), isTrue);
    expect(s.wasDeleted('a2'), isFalse);
    s.reset();
    expect(s.wasDeleted('a1'), isFalse);
  });

  test('removed photos signal the open album every time', () {
    final s = AppState(summaryDebounce: Duration.zero);
    s.notifyMediaRemoved('a1');
    final first = s.mediaRemovedTick;
    s.notifyMediaRemoved('a1');
    expect(s.lastMediaRemovedAlbumId, 'a1');
    expect(s.mediaRemovedTick, first + 1);
  });
}
