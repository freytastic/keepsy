import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/widgets/delete_shared_albums_dialog.dart';

void main() {
  testWidgets('deleting shared albums needs its own explicit agreement',
      (tester) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async {
            result = await showDialog<bool>(
              context: ctx,
              builder: (_) => const DeleteSharedAlbumsDialog(albums: [
                (name: 'Trip', members: 3),
                (name: 'Family', members: 5),
              ]),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('You administer 2 shared albums'), findsOneWidget);
    expect(find.text('Trip · 3 members'), findsOneWidget);

    final delete = find.widgetWithText(TextButton, 'Delete everything');
    expect(tester.widget<TextButton>(delete).onPressed, isNull);

    await tester.tap(find.text('Delete them for everyone'));
    await tester.pump();
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });
}
