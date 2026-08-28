import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shipped camera asset is complete', () async {
    final bytes = await File(
      'lib/assets/onboarding/camera_stage.webp',
    ).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    addTearDown(codec.dispose);

    expect(codec.frameCount, inInclusiveRange(132, 140));

    final frame = await codec.getNextFrame();
    expect(frame.image.width, 1400);
    expect(frame.image.height, 1014);

    var duration = frame.duration;
    frame.image.dispose();
    for (var i = 1; i < codec.frameCount; i++) {
      final next = await codec.getNextFrame();
      duration += next.duration;
      next.image.dispose();
    }

    expect(duration.inMilliseconds, inInclusiveRange(3500, 3700));
  });
}
