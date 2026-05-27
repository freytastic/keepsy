import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/prekey_api.dart' show HandleNotFoundException;
import 'package:keepsy/ui/widgets/add_member_dialog.dart';

Future<void> _open(
    WidgetTester tester, Future<void> Function(String) onInvite) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => Center(
          child: ElevatedButton(
            onPressed: () => showDialog(
                context: ctx, builder: (_) => AddMemberDialog(onInvite: onInvite)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('normalizes input and invites with the canonical handle',
      (tester) async {
    String? captured;
    await _open(tester, (id) async => captured = id);

    await tester.enterText(find.byType(TextField), 'k7f2-9qxm');
    await tester.tap(find.text('Invite'));
    await tester.pumpAndSettle();

    expect(captured, 'K7F29QXM');
  });

  testWidgets('rejects malformed input inline without inviting', (tester) async {
    var called = false;
    await _open(tester, (id) async => called = true);

    await tester.enterText(find.byType(TextField), '!!!');
    await tester.tap(find.text('Invite'));
    await tester.pump();

    expect(called, isFalse);
    expect(find.text('Enter a valid 8-character keepsy ID'), findsOneWidget);
  });

  testWidgets('surfaces "no such user" on HandleNotFoundException',
      (tester) async {
    await _open(tester, (id) async => throw const HandleNotFoundException('K7F29QXM'));

    await tester.enterText(find.byType(TextField), 'K7F29QXM');
    await tester.tap(find.text('Invite'));
    await tester.pumpAndSettle();

    expect(find.text('No keepsy user with that ID'), findsOneWidget);
  });
}
