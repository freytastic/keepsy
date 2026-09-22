import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/providers/upload_queue_model.dart';
import 'package:keepsy/ui/shelf/shelf_layout.dart';
import 'package:keepsy/ui/shelf/shelf_screen.dart';
import 'package:keepsy/ui/shelf/shelf_view_preference.dart';

import '../ui/upload_scaffold.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the stored choice', () {
    test('a fresh install opens stacked', () async {
      final pref =
          await ShelfViewPreference.load(await SharedPreferences.getInstance());
      expect(pref.view, ShelfView.stacked);
    });

    test('compact survives a restart', () async {
      final prefs = await SharedPreferences.getInstance();
      await (await ShelfViewPreference.load(prefs)).set(ShelfView.compact);

      final reopened = await ShelfViewPreference.load(prefs);
      expect(reopened.view, ShelfView.compact);
    });

    test('stacked survives a restart too', () async {
      final prefs = await SharedPreferences.getInstance();
      final pref = await ShelfViewPreference.load(prefs);
      await pref.set(ShelfView.compact);
      await pref.set(ShelfView.stacked);

      expect((await ShelfViewPreference.load(prefs)).view, ShelfView.stacked);
    });

    test('an unknown stored value falls back to stacked', () async {
      SharedPreferences.setMockInitialValues({'keepsy.shelf_view': 'mosaic'});
      final pref =
          await ShelfViewPreference.load(await SharedPreferences.getInstance());
      expect(pref.view, ShelfView.stacked);
    });

    test('listeners hear a change', () async {
      final pref =
          await ShelfViewPreference.load(await SharedPreferences.getInstance());
      var heard = 0;
      pref.addListener(() => heard++);
      await pref.set(ShelfView.compact);
      await pref.set(ShelfView.compact);

      expect(heard, 1, reason: 'choosing the current view is not a change');
    });
  });

  group('the picker', () {
    // The first frame of an animation only records its start time
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    AlbumModel album(String id) => AlbumModel(
          id: id,
          nameCt: null,
          createdAt: DateTime(2026, 8, 1),
          updatedAt: DateTime(2026, 8, 1),
        );

    Future<ShelfViewPreference> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final pref =
          await ShelfViewPreference.load(await SharedPreferences.getInstance());
      final state = AppState()..setAlbums([album('a'), album('b'), album('c')]);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: state),
          ChangeNotifierProvider.value(value: pref),
          ChangeNotifierProvider<UploadQueueModel>.value(
              value: idleUploadQueue()),
        ],
        child: const MaterialApp(home: ShelfScreen()),
      ));
      await tester.pump(const Duration(milliseconds: 600));
      return pref;
    }

    double saidOpacity(WidgetTester tester) => tester
        .widget<Opacity>(find
            .ancestor(
                of: find.byKey(const ValueKey('view-said')),
                matching: find.byType(Opacity))
            .first)
        .opacity;

    testWidgets('one tap switches to Compact and saves it', (tester) async {
      final pref = await pump(tester);

      await tester.tap(find.byKey(const ValueKey('view-trigger')));
      await settle(tester);

      expect(pref.view, ShelfView.compact);
      expect(
          (await SharedPreferences.getInstance())
              .getString('keepsy.shelf_view'),
          'compact');
    });

    testWidgets('a second tap goes back to Stacked', (tester) async {
      final pref = await pump(tester);

      await tester.tap(find.byKey(const ValueKey('view-trigger')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('view-trigger')));
      await settle(tester);

      expect(pref.view, ShelfView.stacked);
    });

    testWidgets('the new layout is named for a moment, then fades',
        (tester) async {
      await pump(tester);
      expect(saidOpacity(tester), 0);

      await tester.tap(find.byKey(const ValueKey('view-trigger')));
      await settle(tester);
      expect(find.text('Compact'), findsOneWidget);
      expect(saidOpacity(tester), 1);

      await tester.pump(const Duration(milliseconds: 1400));
      expect(saidOpacity(tester), 0);
    });

    testWidgets('the toggle is announced with the current layout',
        (tester) async {
      await pump(tester);
      expect(find.bySemanticsLabel('Shelf view: Stacked'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('view-trigger')));
      await settle(tester);
      expect(find.bySemanticsLabel('Shelf view: Compact'), findsOneWidget);
    });

    testWidgets('the toggle is a full size tap target', (tester) async {
      await pump(tester);
      final size = tester.getSize(find.byKey(const ValueKey('view-trigger')));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));
    });
  });
}
