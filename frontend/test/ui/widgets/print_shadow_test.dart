import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/baked_paint.dart';
import 'package:keepsy/ui/widgets/print_card.dart';

// The print shadow as it was drawn before baking: every layer live
class _LiveShadowCard extends StatelessWidget {
  final List<BoxShadow> shadows;
  const _LiveShadowCard(this.shadows);

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Warm.paper,
          borderRadius: BorderRadius.circular(8),
          boxShadow: shadows,
        ),
      );
}

void main() {
  for (final entry in {
    'printShadow': Warm.printShadow,
    'printShadowBack': Warm.printShadowBack,
    'printShadowSmall': Warm.printShadowSmall,
  }.entries) {
    testWidgets('baked ${entry.key} matches the live shadow', (tester) async {
      final boundary = GlobalKey();
      Widget host(Widget card) => MaterialApp(
            home: Center(
              child: RepaintBoundary(
                key: boundary,
                child: Container(
                  width: 420,
                  height: 520,
                  color: Warm.ground,
                  alignment: Alignment.center,
                  child: SizedBox(width: 240, height: 298, child: card),
                ),
              ),
            ),
          );

      Future<List<int>> capture() async {
        final render = boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final bytes = await tester.runAsync(() async {
          final image = await render.toImage(pixelRatio: 3);
          final data =
              await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          image.dispose();
          return data!.buffer.asUint8List();
        });
        return bytes!;
      }

      await tester.pumpWidget(host(_LiveShadowCard(entry.value)));
      final live = await capture();

      // An empty well keeps the comparison on the shadow alone. Mounted on
      // real time: the settle timer and the render run as on a device
      await tester.runAsync(() async {
        await tester
            .pumpWidget(host(PrintCard(shadow: entry.value, blank: true)));
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      await tester.pump();

      final painters = tester
          .widgetList<CustomPaint>(find.descendant(
              of: find.byType(BakedPaint), matching: find.byType(CustomPaint)))
          .map((c) => c.painter.runtimeType.toString());
      expect(painters, contains('_ImagePainter'),
          reason: 'the baked image, not the live fallback, must be on screen');
      final baked = await capture();
      expect(baked.length, live.length);

      // Only compare the shadow: the card face and its antialiased edge are
      // drawn by the same box in both versions
      const w = 420 * 3, h = 520 * 3;
      final card = Rect.fromCenter(
          center: const Offset(w / 2, h / 2), width: 240 * 3, height: 298 * 3);
      var worst = 0;
      var shaded = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          if (card.inflate(6).contains(Offset(x.toDouble(), y.toDouble()))) {
            continue;
          }
          final i = (y * w + x) * 4;
          for (var c = 0; c < 3; c++) {
            final d = (live[i + c] - baked[i + c]).abs();
            if (d > worst) worst = d;
          }
          if ((live[i] - Warm.ground.r * 255).abs() > 2) shaded++;
        }
      }
      expect(shaded, greaterThan(5000), reason: 'the shadow must show');
      // Baked at 2x and drawn at 3x. The live reference is itself a stitched
      // approximation of a large blur, and its seams sit on the card edges;
      // a bake at the exact scale matches within 3
      expect(worst, lessThanOrEqualTo(5));
    });
  }
}
