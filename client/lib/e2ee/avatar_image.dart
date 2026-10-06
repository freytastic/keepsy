import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'file_pipeline.dart';
import 'jpeg_budget.dart';
import 'jpeg_sanity.dart';
import 'sealed_avatar.dart';

const int kAvatarDim = 512;
const int _avatarQuality = 86;
const int _avatarMinQuality = 60;
const int _avatarMinDim = 256;

class AvatarCrop {
  final int x;
  final int y;
  final int side;
  const AvatarCrop({required this.x, required this.y, required this.side});
}

abstract class AvatarImage {
  //Throws UnprocessableImageException for anything that cannot be decoded, same as a photo upload
  static Future<Uint8List> prepare(Uint8List picked,
      {ImageTranscoder? transcode}) async {
    final clean = await FilePipeline.cleanPhoto(picked, transcode: transcode);
    return clean.jpeg;
  }

  // The square, scaled to kAvatarDim and small enough to pad into one blob
  static Future<Uint8List> render(Uint8List cleanJpeg, AvatarCrop crop) =>
      Isolate.run(() => _render(cleanJpeg, crop));
}

Uint8List _render(Uint8List cleanJpeg, AvatarCrop crop) {
  final decoded = img.decodeJpg(cleanJpeg);
  if (decoded == null) {
    throw const UnprocessableImageException('avatar source is not a JPEG');
  }
  final side = crop.side.clamp(
      1, decoded.width < decoded.height ? decoded.width : decoded.height);
  final x = crop.x.clamp(0, decoded.width - side);
  final y = crop.y.clamp(0, decoded.height - side);
  var square = img.copyCrop(decoded, x: x, y: y, width: side, height: side);
  square = resizeLongEdge(square, kAvatarDim);
  square.exif = img.ExifData();
  final jpeg = encodeJpegUnderBudget(
    square,
    budget: kAvatarMaxJpegBytes,
    quality: _avatarQuality,
    minQuality: _avatarMinQuality,
    minDim: _avatarMinDim,
  );
  final clean = JpegSanity.sanitize(jpeg.bytes);
  if (clean == null || clean.bytes.length > kAvatarMaxJpegBytes) {
    throw const UnprocessableImageException('avatar did not encode cleanly');
  }
  return clean.bytes;
}
