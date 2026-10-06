import 'dart:typed_data';
import 'dart:ui' as ui;

class DecryptedImagePreview {
  final Uint8List bytes;
  final int width;
  final int height;

  const DecryptedImagePreview({
    required this.bytes,
    required this.width,
    required this.height,
  });

  double get aspectRatio => width / height;

  static Future<DecryptedImagePreview> inspect(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        return DecryptedImagePreview(
          bytes: bytes,
          width: descriptor.width,
          height: descriptor.height,
        );
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }
}
