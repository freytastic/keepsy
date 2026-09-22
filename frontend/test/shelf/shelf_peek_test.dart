import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/providers/upload_queue_model.dart';
import 'package:keepsy/ui/shelf/album_print.dart';
import 'package:keepsy/ui/shelf/print_style.dart';
import 'package:keepsy/ui/shelf/shelf_peek.dart';
import 'package:keepsy/ui/widgets/print_card.dart';
import 'package:keepsy/ui/shelf/shelf_screen.dart';

import '../ui/upload_scaffold.dart';

void main() {
  AlbumModel album(String id, {int photos = 7}) => AlbumModel(
        id: id,
        nameCt: null,
        createdAt: DateTime(2026, 8, 1),
        updatedAt: DateTime(2026, 8, 1),
        mediaCount: photos,
        activeMemberCount: 3,
      );

  late List<String> opened;
  late List<String> people;

  Future<void> pump(WidgetTester tester, {int photos = 7}) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    opened = [];
    people = [];

    final state = AppState()
      ..setAlbums([album('a', photos: photos), album('b', photos: photos)]);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: state),
        ChangeNotifierProvider<UploadQueueModel>.value(
            value: idleUploadQueue()),
      ],
      child: MaterialApp(
        home: ShelfScreen(
          onOpenAlbum: (a) async => opened.add(a.id),
          onOpenPeople: (a) async => people.add(a.id),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> hold(WidgetTester tester) async {
    await tester.longPress(find.byType(AlbumPrint).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  double shelfOpacity(WidgetTester tester) => tester
      .widget<Opacity>(find
          .ancestor(
              of: find.byType(AlbumPrint).first, matching: find.byType(Opacity))
          .first)
      .opacity;

  testWidgets('a short hold only riffles', (tester) async {
    await pump(tester);
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(AlbumPrint).first));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('Open album'), findsNothing);
  });

  testWidgets('a long hold lifts the print and offers the album menu',
      (tester) async {
    await pump(tester);
    await hold(tester);

    expect(find.text('Open album'), findsOneWidget);
    expect(find.text('People & safety numbers'), findsOneWidget);
    expect(find.text('Soon'), findsOneWidget,
        reason: 'download is not built, so it must not look actionable');
    expect(shelfOpacity(tester), 0,
        reason: 'the lifted print leaves its space on the shelf');
  });

  test('every preview behind the cover fans, capped at two', () {
    expect([
      for (final n in [0, 1, 2, 3, 7, 40]) fanFor(n)
    ], [
      0,
      0,
      1,
      2,
      2,
      2
    ]);
  });

  int liftedPrints(WidgetTester tester) => find
      .descendant(of: find.byType(ShelfPeek), matching: find.byType(PrintCard))
      .evaluate()
      .length;

  testWidgets('both prints underneath fan out below twenty photos',
      (tester) async {
    await pump(tester, photos: 7);
    await hold(tester);
    expect(liftedPrints(tester), 3);
  });

  testWidgets('a two photo album fans the one it has', (tester) async {
    await pump(tester, photos: 2);
    await hold(tester);
    expect(liftedPrints(tester), 2);
  });

  testWidgets('album info swaps in place and back', (tester) async {
    await pump(tester);
    await hold(tester);

    await tester.tap(find.text('Album info'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Last photo'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(opened, isEmpty);

    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Open album'), findsOneWidget);
  });

  testWidgets('open leaves through the tuck and cleans up', (tester) async {
    await pump(tester);
    await hold(tester);

    await tester.tap(find.text('Open album'));
    await tester.pump();
    expect(opened, ['a']);

    await tester.pump(const Duration(milliseconds: 360));
    expect(find.byType(AlbumPrint), findsNWidgets(3),
        reason: 'two on the shelf plus the one tucking away');

    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(AlbumPrint), findsNWidgets(2));
    expect(find.text('Open album'), findsNothing);
    expect(shelfOpacity(tester), 1);
  });

  testWidgets('people opens the album on its people sheet', (tester) async {
    await pump(tester);
    await hold(tester);

    await tester.tap(find.text('People & safety numbers'));
    await tester.pump(const Duration(milliseconds: 900));

    expect(people, ['a']);
    expect(opened, isEmpty);
  });

  testWidgets('back dismisses without acting', (tester) async {
    await pump(tester);
    await hold(tester);

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(find.text('Open album'), findsNothing);
    expect(opened, isEmpty);
    expect(people, isEmpty);
    expect(shelfOpacity(tester), 1);
  });
}
