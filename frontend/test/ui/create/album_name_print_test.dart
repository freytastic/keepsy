import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/create/album_name_print.dart';

void main() {
  Future<void> pump(WidgetTester tester, {bool enabled = true}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AlbumNamePrint(
          controller: TextEditingController(),
          enabled: enabled,
          onChanged: (_) {},
          onSubmitted: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the print settles upright rather than mid-animation',
      (tester) async {
    await pump(tester);

    final t =
        tester.widget<Transform>(find.byKey(AlbumNamePrintState.flightKey));
    expect(t.transform.getTranslation().y, closeTo(0, 0.01));
  });

  testWidgets('the keyboard does not open over the entry animation',
      (tester) async {
    await pump(tester);

    expect(tester.widget<TextField>(find.byType(TextField)).autofocus, isFalse);
  });

  testWidgets('flying out clears the frame upward before it resolves',
      (tester) async {
    final key = GlobalKey<AlbumNamePrintState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AlbumNamePrint(
          key: key,
          controller: TextEditingController(),
          onChanged: (_) {},
          onSubmitted: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final flight = key.currentState!.flyOut();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));

    final moved = tester
        .widget<Transform>(find.byKey(AlbumNamePrintState.flightKey))
        .transform
        .getTranslation()
        .y;
    expect(moved, lessThan(0), reason: 'the mock sends the print upward');

    await tester.pumpAndSettle();
    await flight;
  });

  testWidgets('the field is disabled while the album is being created',
      (tester) async {
    await pump(tester, enabled: false);

    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
  });
}
