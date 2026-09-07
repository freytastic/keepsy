import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/create/create_copy.dart';
import 'package:keepsy/ui/create/invite_id_field.dart';

void main() {
  late List<String> ids;

  Future<void> pump(WidgetTester tester, {List<String>? initial}) async {
    ids = [...?initial];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => InviteIdField(
            ids: ids,
            onChanged: (next) => setState(() => ids = next),
          ),
        ),
      ),
    ));
  }

  Future<void> enter(WidgetTester tester, String text) async {
    await tester.tap(find.text(CreateCopy.addPerson));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  testWidgets('a valid id becomes a chip in canonical display form',
      (tester) async {
    await pump(tester);

    await enter(tester, 'abcd-2345');

    expect(ids, ['ABCD2345']);
    expect(find.text('ABCD-2345'), findsOneWidget);
  });

  testWidgets('an invalid id is refused and nothing is added', (tester) async {
    await pump(tester);

    await enter(tester, 'nope');

    expect(ids, isEmpty);
    expect(find.text(CreateCopy.idInvalid), findsOneWidget);
  });

  testWidgets('the same id cannot be added twice', (tester) async {
    await pump(tester, initial: ['ABCD2345']);

    await enter(tester, 'ABCD-2345');

    expect(ids, ['ABCD2345']);
    expect(find.text(CreateCopy.idDuplicate), findsOneWidget);
  });

  testWidgets('a chip can be removed', (tester) async {
    await pump(tester, initial: ['ABCD2345', 'WXYZ6789']);

    await tester.tap(find.byTooltip('${CreateCopy.removePerson} ABCD-2345'));
    await tester.pumpAndSettle();

    expect(ids, ['WXYZ6789']);
  });

  testWidgets('the privacy note reflects whether anyone was added',
      (tester) async {
    await pump(tester);
    expect(find.text(CreateCopy.privacyEmpty), findsOneWidget);

    await enter(tester, 'ABCD2345');

    expect(find.text(CreateCopy.privacyWithInvites), findsOneWidget);
  });
}
