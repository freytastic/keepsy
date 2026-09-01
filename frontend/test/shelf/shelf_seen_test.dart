import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/shelf/shelf_data.dart';
import 'package:keepsy/ui/shelf/shelf_screen.dart';

void main() {
  testWidgets('opening marks the current generation before navigation',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final album = AlbumModel(
      id: 'album-1',
      nameCt: null,
      createdAt: DateTime(2026, 8, 1),
      updatedAt: DateTime(2026, 8, 1),
      mediaCount: 3,
      mediaGeneration: 3,
      hasSummary: true,
    );
    final state = AppState()
      ..setAlbums([album])
      ..setAlbumDisplayName(album.id, 'Trip');
    final seen = InMemorySeenStore();
    int? seenWhenOpened;

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: state),
        ListenableProvider<SeenStore>.value(value: seen),
      ],
      child: MaterialApp(
        home: ShelfScreen(
          onOpenAlbum: (_) async {
            seenWhenOpened = seen.lastSeen(album.id);
          },
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Trip').last);
    await tester.pump();

    expect(seenWhenOpened, 3);
  });
}
