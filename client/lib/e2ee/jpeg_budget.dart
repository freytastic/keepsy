import 'dart:typed_data';

import 'package:image/image.dart' as img;

class BudgetedJpeg {
  final Uint8List bytes;
  final int width;
  final int height;
  final int quality;
  const BudgetedJpeg(this.bytes, this.width, this.height, this.quality);
}

// Steps quality down first, then shrinks the long edge by a quarter and starts
// over. Stops at minDim even if the budget is still exceeded
BudgetedJpeg encodeJpegUnderBudget(
  img.Image src, {
  required int budget,
  required int quality,
  required int minQuality,
  required int minDim,
}) {
  var image = src;
  var q = quality;
  while (true) {
    final bytes = img.encodeJpg(image, quality: q);
    if (bytes.length <= budget) {
      return BudgetedJpeg(bytes, image.width, image.height, q);
    }
    if (q > minQuality) {
      q = q - 8 < minQuality ? minQuality : q - 8;
      continue;
    }
    final longEdge = image.width >= image.height ? image.width : image.height;
    if (longEdge <= minDim) {
      return BudgetedJpeg(bytes, image.width, image.height, q);
    }
    image = resizeLongEdge(image, (longEdge * 3) ~/ 4);
    q = quality;
  }
}

img.Image resizeLongEdge(img.Image src, int maxDim) {
  final longEdge = src.width >= src.height ? src.width : src.height;
  if (longEdge <= maxDim) return src;
  return src.width >= src.height
      ? img.copyResize(src,
          width: maxDim, interpolation: img.Interpolation.average)
      : img.copyResize(src,
          height: maxDim, interpolation: img.Interpolation.average);
}
