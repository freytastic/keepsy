import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/ui/widgets/camera_stage.dart';

Future<({int frames, int width, int height, int ms})> _read(String path) async {
  final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
  try {
    final first = await codec.getNextFrame();
    final width = first.image.width;
    final height = first.image.height;
    var duration = first.duration;
    first.image.dispose();
    for (var i = 1; i < codec.frameCount; i++) {
      final next = await codec.getNextFrame();
      duration += next.duration;
      next.image.dispose();
    }
    return (
      frames: codec.frameCount,
      width: width,
      height: height,
      ms: duration.inMilliseconds,
    );
  } finally {
    codec.dispose();
  }
}

void main() {
  test('shipped camera asset is complete', () async {
    final clip = await _read('lib/assets/onboarding/camera_stage.webp');
    expect(clip.frames, inInclusiveRange(132, 140));
    expect(clip.width, 1400);
    expect(clip.height, 1014);
    expect(clip.ms, inInclusiveRange(3500, 3700));
  });

  test('lite clip keeps the master timeline at 30 fps', () async {
    final master = await _read('lib/assets/onboarding/camera_stage.webp');
    final lite = await _read('lib/assets/onboarding/camera_stage_lite.webp');
    expect(lite.width, 720);
    expect(lite.width / lite.height,
        closeTo(master.width / master.height, 0.01));
    expect(lite.frames, inInclusiveRange(100, 104));
    expect(lite.ms, master.ms);
  });

  test('settled still matches the master crop', () async {
    final still = await _read('lib/assets/onboarding/camera_stage_still.webp');
    expect(still.frames, 1);
    expect(still.width, 1400);
    expect(still.height, 1014);
  });

  test('probe holds the expensive stretch at full width', () async {
    final probe = await _read('lib/assets/onboarding/camera_stage_probe.webp');
    expect(probe.frames, 5);
    expect(probe.width, 1400);
    expect(probe.height, 1014);
  });

  group('chooseStageTier', () {
    const budget = Duration(milliseconds: 25);

    test('keeps the full clip on a phone that decodes it in time', () {
      expect(chooseStageTier([26000, 40000, 25500], budget), StageTier.full);
    });

    test('drops to lite when late frames miss the budget', () {
      expect(chooseStageTier([98000], budget), StageTier.lite);
    });

    test('defaults to full with no measurement', () {
      expect(chooseStageTier(const [], budget), StageTier.full);
    });
  });
}
