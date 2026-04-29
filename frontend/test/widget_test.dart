// Smoke test scaffold. Real widget tests land per-section as the screens
// grow (album detail in P0.3, encrypted thumbnails in P5.3, etc.).
//
// Kept intentionally minimal so `flutter test` is green between sections.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('placeholder smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('keepsy'))),
    );
    expect(find.text('keepsy'), findsOneWidget);
  });
}
