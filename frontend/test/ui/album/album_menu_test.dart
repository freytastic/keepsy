import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/album/album_copy.dart';
import 'package:keepsy/ui/album/album_menu.dart';

void main() {
  late List<String> chosen;

  Future<void> open(WidgetTester tester) async {
    chosen = [];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => AlbumMenu.show(
                context,
                onSelectPhotos: () => chosen.add('select'),
                onDownloadAlbum: () => chosen.add('download'),
                onAlbumInfo: () => chosen.add('info'),
              ),
              child: const Text('more'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('more'));
    await tester.pumpAndSettle();
  }

  testWidgets('offers the four entries in the mock order', (tester) async {
    await open(tester);

    final labels = tester
        .widgetList<Text>(find.descendant(
          of: find.byType(AlbumMenu),
          matching: find.byType(Text),
        ))
        .map((t) => t.data)
        .whereType<String>()
        .where((s) => s != AlbumCopy.laterBadge)
        .toList();

    expect(labels, [
      AlbumCopy.selectPhotos,
      AlbumCopy.downloadAlbum,
      AlbumCopy.peopleAndSafety,
      AlbumCopy.albumInfo,
    ]);
  });

  testWidgets('nothing sits between the menu and the album but a tap target',
      (tester) async {
    await open(tester);

    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('choosing an entry closes the menu and reports it',
      (tester) async {
    await open(tester);

    await tester.tap(find.text(AlbumCopy.albumInfo));
    await tester.pumpAndSettle();

    expect(chosen, ['info']);
    expect(find.byType(AlbumMenu), findsNothing);
  });

  testWidgets('tapping away closes without choosing anything', (tester) async {
    await open(tester);

    await tester.tapAt(const Offset(20, 420));
    await tester.pumpAndSettle();

    expect(chosen, isEmpty);
    expect(find.byType(AlbumMenu), findsNothing);
  });

  testWidgets('people and safety numbers is present but not yet wired',
      (tester) async {
    await open(tester);

    await tester.tap(find.text(AlbumCopy.peopleAndSafety));
    await tester.pumpAndSettle();

    expect(chosen, isEmpty, reason: 'its screen lands in a later pass');
    expect(find.text(AlbumCopy.laterBadge), findsOneWidget);
  });
}
