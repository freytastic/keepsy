import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:keepsy/e2ee/identity_trust.dart';
import 'package:keepsy/ui/widgets/safety_number_sheet.dart';

const _digits = '12345 67890 12345 67890 12345 67890';

Future<void> _pump(
  WidgetTester tester, {
  required TrustState state,
  VoidCallback? onVerify,
}) {
  return tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SafetyNumberSheet(
        displayName: 'Sami',
        digits: _digits,
        state: state,
        onVerify: onVerify ?? () {},
      ),
    ),
  ));
}

void main() {
  testWidgets('shows the digits and names the peer', (tester) async {
    await _pump(tester, state: TrustState.unverified);

    expect(find.text(_digits), findsOneWidget);
    expect(find.textContaining('Sami'), findsWidgets);
  });

  // TOFU cannot rule out a MITM who was present at first sight, so an
  // un compared key must never be dressed up as safe
  testWidgets('unverified never claims the connection is safe or verified',
      (tester) async {
    await _pump(tester, state: TrustState.unverified);

    expect(find.text('Not verified'), findsOneWidget);
    expect(find.textContaining('Mark as verified'), findsOneWidget);

    // what must NOT appear is a claim
    // that the connection itself is already safe / secure / verified
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => (t.data ?? '').toLowerCase())
        .join(' ');
    expect(
        texts, isNot(matches(RegExp(r'\b(safe|secure|encrypted|private)\b'))));
    expect(texts, isNot(contains('is verified')));
  });

  // Verification has no undo, is not album scoped, and may unblock key installs
  // A reflex tap while viewing substituted digits must not grant it
  testWidgets('Mark as verified asks the user to confirm the digits matched',
      (tester) async {
    var verified = false;
    await _pump(tester,
        state: TrustState.unverified, onVerify: () => verified = true);

    await tester.tap(find.textContaining('Mark as verified'));
    await tester.pumpAndSettle();

    expect(verified, isFalse, reason: 'one tap must not be enough');
    expect(find.textContaining('match exactly'), findsOneWidget);
  });

  testWidgets('confirming the prompt fires onVerify', (tester) async {
    var verified = false;
    await _pump(tester,
        state: TrustState.unverified, onVerify: () => verified = true);

    await tester.tap(find.textContaining('Mark as verified'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('They matched'));
    await tester.pumpAndSettle();

    expect(verified, isTrue);
  });

  testWidgets('dismissing the prompt leaves the key unverified',
      (tester) async {
    var verified = false;
    await _pump(tester,
        state: TrustState.unverified, onVerify: () => verified = true);

    await tester.tap(find.textContaining('Mark as verified'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("They didn't"));
    await tester.pumpAndSettle();

    expect(verified, isFalse);
  });

  testWidgets('verified shows the confirmed state and no verify button',
      (tester) async {
    await _pump(tester, state: TrustState.verified);

    expect(find.text('Verified'), findsOneWidget);
    expect(find.textContaining('Mark as verified'), findsNothing);
  });

  // The old accept button moved trust without comparing digits. Now that
  // verification also grants signer authority, that shortcut would bypass the
  // out-of-band check and still serves no valid beta workflow
  testWidgets('a changed key cannot be accepted without comparing digits',
      (tester) async {
    await _pump(tester, state: TrustState.changed);

    expect(find.textContaining('security key changed'), findsOneWidget);
    expect(find.textContaining('Mark as verified'), findsOneWidget);
    expect(find.textContaining("It's them"), findsNothing);
    expect(find.textContaining('new phone'), findsNothing);
  });
}
