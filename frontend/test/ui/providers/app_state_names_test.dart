import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/ui/providers/app_state.dart';

AlbumModel _album(String id, String? nameCt) => AlbumModel(
      id: id,
      nameCt: nameCt,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

// Fake resolver: 'REAL' decrypts to 'Real Name', anything else is a placeholder
Future<String> _fakeResolver(String albumId, String? nameCt) async {
  return nameCt == 'REAL' ? 'Real Name' : 'Untitled Album';
}

void main() {
  test('setAlbums resolves titles via the attached resolver', () async {
    final s = AppState();
    s.attachAlbumNameResolver(_fakeResolver);
    s.setAlbums([_album('a', 'REAL')]);
    await Future<void>.delayed(Duration.zero);
    expect(s.albumDisplayName('a'), 'Real Name');
  });

  test('applyAlbumNameCt survives a later refreshAlbumNames (no clobber)',
      () async {
    final s = AppState();
    s.attachAlbumNameResolver(_fakeResolver);
    // Created album lands with a placeholder nameCt (create time), resolves to
    // the fallback title
    s.setAlbums([_album('a', 'placeholder')]);
    await Future<void>.delayed(Duration.zero);
    expect(s.albumDisplayName('a'), 'Untitled Album');

    // Background patch completes: update both the cached name and stored nameCt
    s.applyAlbumNameCt('a', 'REAL', 'Real Name');
    expect(s.albumDisplayName('a'), 'Real Name');

    // A later refresh (eg WS reconnect) must NOT regress it to the placeholder
    s.refreshAlbumNames();
    await Future<void>.delayed(Duration.zero);
    expect(s.albumDisplayName('a'), 'Real Name');
  });

  test('an in-flight stale resolve does not clobber applyAlbumNameCt',
      () async {
    final s = AppState();
    final gate = Completer<void>();
    // The placeholder resolve blocks on the gate; the real one returns at once
    s.attachAlbumNameResolver((id, nameCt) async {
      if (nameCt == 'placeholder') {
        await gate.future;
        return 'Untitled Album';
      }
      return 'Real Name';
    });
    s.setAlbums([_album('a', 'placeholder')]); // starts the blocked resolve
    await Future<void>.delayed(Duration.zero);

    // Patch lands the real title while the placeholder resolve is still pending
    s.applyAlbumNameCt('a', 'REAL', 'Real Name');
    expect(s.albumDisplayName('a'), 'Real Name');

    gate.complete(); // stale resolve finishes now
    await Future<void>.delayed(Duration.zero);
    expect(s.albumDisplayName('a'), 'Real Name'); // guard held
  });

  test('refreshAlbumNames re-resolves after MKs become available', () async {
    final s = AppState();
    // Albums set before a resolver is attached (resolver depends on keystore)
    s.setAlbums([_album('a', 'REAL')]);
    // No resolver yet -> nothing cached
    expect(s.albumDisplayName('a'), isNull);
    s.attachAlbumNameResolver(_fakeResolver);
    await Future<void>.delayed(Duration.zero);
    expect(s.albumDisplayName('a'), 'Real Name');
  });

  test('setAlbums does not regress a locally-applied title to a stale '
      'placeholder', () async {
    final s = AppState();
    s.attachAlbumNameResolver(_fakeResolver);
    s.setAlbums([_album('a', 'placeholder')]);
    await Future<void>.delayed(Duration.zero);
    expect(s.albumDisplayName('a'), 'Untitled Album');

    // create PATCH applied locally
    s.applyAlbumNameCt('a', 'REAL', 'Real Name');
    expect(s.albumDisplayName('a'), 'Real Name');

    // a stale GET carrying the placeholder arrives AFTER the local apply
    s.setAlbums([_album('a', 'placeholder')]);
    await Future<void>.delayed(Duration.zero);
    expect(s.albumDisplayName('a'), 'Real Name'); // overlaid, not regressed

    // once the server echoes the real nameCt the override is dropped
    s.setAlbums([_album('a', 'REAL')]);
    await Future<void>.delayed(Duration.zero);
    expect(s.albumDisplayName('a'), 'Real Name');
  });

  test('removeAlbum drops the cached display name', () async {
    final s = AppState();
    s.attachAlbumNameResolver(_fakeResolver);
    s.setAlbums([_album('a', 'REAL')]);
    await Future<void>.delayed(Duration.zero);
    expect(s.albumDisplayName('a'), 'Real Name');
    s.removeAlbum('a');
    expect(s.albumDisplayName('a'), isNull);
  });

  test('clearDisplayNameCaches wipes cached titles (logout)', () async {
    final s = AppState();
    s.attachAlbumNameResolver(_fakeResolver);
    s.setAlbums([_album('a', 'REAL')]);
    await Future<void>.delayed(Duration.zero);
    expect(s.albumDisplayName('a'), 'Real Name');
    s.clearDisplayNameCaches();
    expect(s.albumDisplayName('a'), isNull);
  });
}
