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

    testWidgets('offers Stacked and Compact behind View', (tester) async {
      await pump(tester);
      expect(find.text('Compact'), findsNothing);

      await tester.tap(find.text('View'));
      await settle(tester);

      expect(find.text('Stacked'), findsOneWidget);
      expect(find.text('Compact'), findsOneWidget);
      // find.text also matches invisible text, so check it actually shows
      final fade = tester.widget<Opacity>(find
          .ancestor(of: find.text('Compact'), matching: find.byType(Opacity))
          .first);
      expect(fade.opacity, 1);
      expect(find.byKey(const ValueKey('view-check-stacked')), findsOneWidget);
      expect(find.byKey(const ValueKey('view-check-compact')), findsNothing);
    });

    testWidgets('choosing Compact saves it and closes the menu',
        (tester) async {
      final pref = await pump(tester);

      await tester.tap(find.text('View'));
      await settle(tester);
      await tester.tap(find.text('Compact'));
      await settle(tester);

      expect(pref.view, ShelfView.compact);
      expect(
          (await SharedPreferences.getInstance())
              .getString('keepsy.shelf_view'),
          'compact');
      expect(find.text('Stacked'), findsNothing);
    });

    testWidgets('tapping outside closes without changing anything',
        (tester) async {
      final pref = await pump(tester);

      await tester.tap(find.text('View'));
      await settle(tester);
      await tester.tapAt(const Offset(40, 1300));
      await settle(tester);

      expect(find.text('Compact'), findsNothing);
      expect(pref.view, ShelfView.stacked);
    });

    // Closing the root overlay must not leave the app
    testWidgets('back closes the menu first', (tester) async {
      await pump(tester);
      await tester.tap(find.text('View'));
      await settle(tester);

      final handled = await tester.binding.handlePopRoute();
      await settle(tester);

      expect(handled, isTrue);
      expect(find.text('Compact'), findsNothing);
      expect(find.text('View'), findsOneWidget);
    });

    testWidgets('the trigger and options are full size tap targets',
        (tester) async {
      await pump(tester);
      expect(tester.getSize(find.byKey(const ValueKey('view-trigger'))).height,
          greaterThanOrEqualTo(48));

      await tester.tap(find.text('View'));
      await settle(tester);
      expect(
          tester
              .getSize(find.byKey(const ValueKey('view-option-compact')))
              .height,
          greaterThanOrEqualTo(48));
    });
  });
}
