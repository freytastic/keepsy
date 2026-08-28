import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/screens/onboarding_screen.dart';
import 'package:keepsy/ui/widgets/camera_stage.dart';

void main() {
  Future<void> pumpEmailWithKeyboard(
    WidgetTester tester, {
    required Size screen,
    required double keyboardHeight,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = screen;
    // Compensate for the test font's wider glyphs
    tester.platformDispatcher.textScaleFactorTestValue = 0.72;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(const MaterialApp(home: OnboardingScreen()));
    expect(tester.takeException(), isNull, reason: 'intro layout overflowed');
    await tester.tap(find.text('Continue'));
    // Finish the phase transition before opening the keyboard
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.takeException(), isNull,
        reason: 'email transition layout overflowed');

    tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.takeException(), isNull,
        reason: 'compact keyboard layout overflowed');
  }

  void expectSeparatedAndCentered(WidgetTester tester, Size screen) {
    final camera = tester.getRect(find.byType(CameraStage));
    final description = tester.getRect(find.text(
      'We’ll send a one-time sign-in code to your email.',
    ));
    final field = tester.getRect(find.byType(TextField));
    final action = tester.getRect(find.text('Send code'));

    expect(camera.bottom, lessThanOrEqualTo(description.top));
    expect(description.bottom, lessThan(field.top));
    expect(field.bottom, lessThan(action.top));
    expect(description.center.dx, closeTo(screen.width / 2, 0.5));
    expect(field.center.dx, closeTo(screen.width / 2, 0.5));
  }

  testWidgets('keyboard layout stays separated on a tall phone',
      (tester) async {
    const screen = Size(390, 844);
    await pumpEmailWithKeyboard(
      tester,
      screen: screen,
      keyboardHeight: 320,
    );
    expectSeparatedAndCentered(tester, screen);
  });

  testWidgets('keyboard layout adapts on a shorter phone', (tester) async {
    const screen = Size(360, 740);
    await pumpEmailWithKeyboard(
      tester,
      screen: screen,
      keyboardHeight: 300,
    );
    expectSeparatedAndCentered(tester, screen);
  });

  testWidgets('email composition has no underline and remains centred',
      (tester) async {
    const screen = Size(390, 844);
    await pumpEmailWithKeyboard(
      tester,
      screen: screen,
      keyboardHeight: 320,
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.textAlignVertical, TextAlignVertical.center);
    expect(
      field.spellCheckConfiguration,
      const SpellCheckConfiguration.disabled(),
    );

    field.controller!.value = const TextEditingValue(
      text: 'hello@example.com',
      selection: TextSelection.collapsed(offset: 17),
      composing: TextRange(start: 6, end: 17),
    );
    final span = field.controller!.buildTextSpan(
      context: tester.element(find.byType(TextField)),
      style: field.style,
      withComposing: true,
    );

    expect(span.toPlainText(), 'hello@example.com');
    expect(span.style?.decoration, isNot(TextDecoration.underline));
    expect(span.children, isNull,
        reason: 'the composing range must not receive a decorated child span');
  });
}
