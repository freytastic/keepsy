import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/pressable_scale.dart';

void main() {
  double currentScale(WidgetTester tester) => tester
      .widget<AnimatedScale>(find.descendant(
        of: find.byType(PressableScale),
        matching: find.byType(AnimatedScale),
      ))
      .scale;

  Future<void> pump(WidgetTester tester,
      {VoidCallback? onTap, bool haptic = false}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: PressableScale(
            onTap: onTap,
            haptic: haptic,
            child: const SizedBox(width: 120, height: 44),
          ),
        ),
      ),
    ));
  }

  testWidgets('shrinks while held and springs back on release', (tester) async {
    await pump(tester, onTap: () {});
    expect(currentScale(tester), 1);

    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(PressableScale)));
    await tester.pump();
    expect(currentScale(tester), Warm.pressScale);

    await gesture.up();
    await tester.pump();
    expect(currentScale(tester), 1);
  });

  testWidgets('springs back when the gesture is cancelled', (tester) async {
    await pump(tester, onTap: () {});

    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(PressableScale)));
    await tester.pump();
    expect(currentScale(tester), Warm.pressScale);

    await gesture.cancel();
    await tester.pump();

    expect(currentScale(tester), 1);
  });

  testWidgets('a disabled control does not react to touch', (tester) async {
    await pump(tester);

    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(PressableScale)));
    await tester.pump();

    expect(currentScale(tester), 1);
    await gesture.up();
  });

  testWidgets('reports the tap', (tester) async {
    var taps = 0;
    await pump(tester, onTap: () => taps++);

    await tester.tap(find.byType(PressableScale));
    await tester.pump();

    expect(taps, 1);
  });
}
