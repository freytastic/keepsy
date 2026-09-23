import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:keepsy/e2ee/avatar_image.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';
import 'package:keepsy/e2ee/sealed_avatar.dart';

Uint8List _jpeg(int w, int h) {
  final image = img.Image(width: w, height: h);
  for (final p in image) {
    p
      ..r = (p.x * 7) % 256
      ..g = (p.y * 5) % 256
      ..b = (p.x + p.y) % 256;
  }
  return img.encodeJpg(image, quality: 95);
}

void main() {
  test('crops a square and scales it down to the avatar size', () async {
    final out = await AvatarImage.render(
        _jpeg(1600, 1200), const AvatarCrop(x: 300, y: 100, side: 1000));
    final decoded = img.decodeJpg(out)!;
    expect(decoded.width, kAvatarDim);
    expect(decoded.height, kAvatarDim);
    expect(out.length, lessThanOrEqualTo(kAvatarMaxJpegBytes));
  });

  test('keeps a small crop at its own size', () async {
    final out = await AvatarImage.render(
        _jpeg(400, 300), const AvatarCrop(x: 10, y: 10, side: 200));
    final decoded = img.decodeJpg(out)!;
    expect((decoded.width, decoded.height), (200, 200));
  });

  test('clamps a crop that runs off the image', () async {
    final out = await AvatarImage.render(
        _jpeg(300, 500), const AvatarCrop(x: 250, y: 480, side: 900));
    final decoded = img.decodeJpg(out)!;
    expect((decoded.width, decoded.height), (300, 300));
  });

  test('writes no metadata segments', () async {
    final out = await AvatarImage.render(
        _jpeg(600, 600), const AvatarCrop(x: 0, y: 0, side: 600));
    for (var i = 0; i + 1 < out.length; i++) {
      if (out[i] != 0xFF) continue;
      final m = out[i + 1];
      if (m == 0xDA) break;
      expect(m >= 0xE1 && m <= 0xEF, isFalse,
          reason: 'APP marker 0x${m.toRadixString(16)} survived');
      expect(m, isNot(0xFE));
    }
  });

  test('refuses what it cannot decode', () async {
    await expectLater(
        AvatarImage.prepare(Uint8List.fromList(List.filled(64, 7))),
        throwsA(isA<UnprocessableImageException>()));
  });
}
