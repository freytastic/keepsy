import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/blur_scrim.dart';

void main() {
  Future<(AnimationController, ValueNotifier<int>)> pump(
      WidgetTester tester) async {
    final c = AnimationController(vsync: tester, duration: Warm.quick);
    final taps = ValueNotifier(0);
    addTearDown(c.dispose);
    addTearDown(taps.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Stack(fit: StackFit.expand, children: [
        const ColoredBox(color: Colors.white),
        BlurScrim(
          progress: c,
          color: Warm.peekScrim,
          onTap: () => taps.value++,
        ),
      ]),
    ));
    return (c, taps);
  }

  testWidgets('keeps one fixed filter behind the opacity transition',
      (tester) async {
    final (c, _) = await pump(tester);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(tester.widget<BackdropFilter>(find.byType(BackdropFilter)).blendMode,
        BlendMode.src);
    final fade = find.descendant(
      of: find.byType(BlurScrim),
      matching: find.byType(FadeTransition),
    );
    expect(tester.widget<FadeTransition>(fade).opacity, c);
    c.value = 0.5;
    await tester.pump();
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('dismisses from the entire scrim', (tester) async {
    final (c, taps) = await pump(tester);
    c.value = 1;
    await tester.pump();

    await tester.tap(find.byType(BlurScrim));
    expect(taps.value, 1);
  });
}
