import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/warm_button.dart';

// The glow as it was drawn before caching: a live blur on every frame
class _LiveGlow extends StatelessWidget {
  const _LiveGlow();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              radius: 2.4,
              colors: [
                Warm.orbPeach.withValues(alpha: 0.55),
                Warm.orbBlush.withValues(alpha: 0.28),
                Warm.orbPeach.withValues(alpha: 0),
              ],
              stops: const [0, 0.45, 0.72],
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('the cached glow paints the same pixels as the live blur',
      (tester) async {
    final boundary = GlobalKey();
    Widget host(Widget glow) => MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: boundary,
              child: SizedBox(
                width: 300,
                height: 56,
                child: ColoredBox(color: Colors.black, child: glow),
              ),
            ),
          ),
        );

    Future<List<int>> capture() async {
      final render = boundary.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final bytes = await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: 3);
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        return data!.buffer.asUint8List();
      });
      return bytes!;
    }

    await tester.pumpWidget(host(const _LiveGlow()));
    final live = await capture();

    await tester.pumpWidget(host(const WarmGlow(lit: true, radius: 28)));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ImageFiltered), findsNothing,
        reason: 'the cached image replaces the live blur');
    expect(find.byType(RawImage), findsOneWidget);
    final cached = await capture();

    expect(cached.length, live.length);
    var worst = 0;
    var lit = 0;
    for (var i = 0; i < live.length; i++) {
      final d = (live[i] - cached[i]).abs();
      if (d > worst) worst = d;
      if (i % 4 != 3 && live[i] > 20) lit++;
    }
    expect(lit, greaterThan(1000), reason: 'the glow must actually show');
    expect(worst, lessThanOrEqualTo(2));
  });
}
