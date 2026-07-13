import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:keepsy/e2ee/identity_trust.dart';
import 'package:keepsy/ui/widgets/safety_number_sheet.dart';

const _digits = '12345 67890 12345 67890 12345 67890';

Future<void> _pump(
  WidgetTester tester, {
  required TrustState state,
  VoidCallback? onVerify,
  VoidCallback? onAccept,
}) {
  return tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SafetyNumberSheet(
        displayName: 'Sami',
        digits: _digits,
        state: state,
        dark: true,
        accent: Colors.teal,
        onVerify: onVerify ?? () {},
        onAccept: onAccept ?? () {},
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

  testWidgets('tapping Mark as verified fires onVerify', (tester) async {
    var verified = false;
    await _pump(tester,
        state: TrustState.unverified, onVerify: () => verified = true);

    await tester.tap(find.textContaining('Mark as verified'));
    await tester.pump();

    expect(verified, isTrue);
  });

  testWidgets('verified shows the confirmed state and no verify button',
      (tester) async {
    await _pump(tester, state: TrustState.verified);

    expect(find.text('Verified'), findsOneWidget);
    expect(find.textContaining('Mark as verified'), findsNothing);
  });

  testWidgets('changed leads with a warning and offers verify or accept',
      (tester) async {
    var accepted = false;
    await _pump(tester,
        state: TrustState.changed, onAccept: () => accepted = true);

    expect(find.textContaining('security key changed'), findsOneWidget);
    expect(find.textContaining('Mark as verified'), findsOneWidget);

    await tester.tap(find.textContaining("It's them"));
    await tester.pump();
    expect(accepted, isTrue);
  });
}
