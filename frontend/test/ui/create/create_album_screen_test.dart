import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/create/create_album_screen.dart';
import 'package:keepsy/ui/create/create_copy.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/warm_button.dart';

void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: CreateAlbumScreen()));
    await tester.pumpAndSettle();
  }

  Future<void> nameIt(WidgetTester tester, String name) async {
    await tester.enterText(
        find.widgetWithText(TextField, CreateCopy.namePlaceholder), name);
    await tester.pump();
  }

  Future<void> addId(WidgetTester tester, String id) async {
    await tester.tap(find.text(CreateCopy.addPerson));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, CreateCopy.idPlaceholder), id);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  WarmButton cta(WidgetTester tester) =>
      tester.widget<WarmButton>(find.byType(WarmButton));

  testWidgets('the album cannot be created without a name', (tester) async {
    await pump(tester);

    expect(cta(tester).onTap, isNull);

    await nameIt(tester, 'Lisbon');

    expect(cta(tester).onTap, isNotNull);
  });

  testWidgets('whitespace alone is not a name', (tester) async {
    await pump(tester);
    await nameIt(tester, '   ');

    expect(cta(tester).onTap, isNull);
  });

  testWidgets('the call to action absorbs what the skip button used to say',
      (tester) async {
    await pump(tester);
    await nameIt(tester, 'Lisbon');

    expect(find.text(CreateCopy.createOnly), findsOneWidget);

    await addId(tester, 'ABCD2345');

    expect(find.text(CreateCopy.createAndInvite(1)), findsOneWidget);

    await addId(tester, 'WXYZ6789');

    expect(find.text(CreateCopy.createAndInvite(2)), findsOneWidget);
  });

  testWidgets('the shelf stays visible through a blurred warm scrim',
      (tester) async {
    await pump(tester);

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, Colors.transparent,
        reason: 'an opaque page would hide the shelf underneath');

    final filter =
        tester.widget<BackdropFilter>(find.byType(BackdropFilter).first);
    expect(filter.filter, isA<ui.ImageFilter>());

    expect(
      find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == Warm.glassScrim),
      findsOneWidget,
      reason: 'a neutral scrim over blurred cream reads grey',
    );
  });
}
