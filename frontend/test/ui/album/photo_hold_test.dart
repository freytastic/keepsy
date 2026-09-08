import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/album/photo_hold.dart';

void main() {
  testWidgets('opens at 240ms and ignores an early release', (tester) async {
    var opens = 0;
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: PhotoHold(
          onStart: (_) => opens++,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      ),
    ));

    await tester.tap(find.byType(PhotoHold));
    expect(taps, 1);

    final early =
        await tester.startGesture(tester.getCenter(find.byType(PhotoHold)));
    await tester.pump(const Duration(milliseconds: 239));
    await early.up();
    await tester.pump();
    expect(opens, 0);

    final held =
        await tester.startGesture(tester.getCenter(find.byType(PhotoHold)));
    await tester.pump(PhotoHold.duration);
    expect(opens, 1);
    await held.up();
    expect(taps, 2);
  });

  testWidgets('scrolling cancels the hold', (tester) async {
    var opens = 0;
    await tester.pumpWidget(MaterialApp(
      home: SingleChildScrollView(
        child: Column(
          children: [
            PhotoHold(
              onStart: (_) => opens++,
              child: const SizedBox(width: 300, height: 500),
            ),
            const SizedBox(height: 1000),
          ],
        ),
      ),
    ));

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(PhotoHold)));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump(PhotoHold.duration);
    await gesture.up();

    expect(opens, 0);
  });
}
