import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

// Tiled noise prevents banding without a per frame shader
class PaperGrain extends StatefulWidget {
  final double opacity;

  const PaperGrain({super.key, this.opacity = 0.03});

  @override
  State<PaperGrain> createState() => _PaperGrainState();
}

class _PaperGrainState extends State<PaperGrain> {
  static Future<ui.Image>? _tile;
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    (_tile ??= _build()).then((img) {
      if (mounted) setState(() => _image = img);
    });
  }

  static Future<ui.Image> _build() {
    const size = 128;
    final rng = Random(0x6B65);
    final pixels = Uint8List(size * size * 4);
    for (var i = 0; i < size * size; i++) {
      final v = rng.nextInt(256);
      pixels[i * 4] = v;
      pixels[i * 4 + 1] = v;
      pixels[i * 4 + 2] = v;
      pixels[i * 4 + 3] = 255;
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        pixels, size, size, ui.PixelFormat.rgba8888, done.complete);
    return done.future;
  }

  @override
  Widget build(BuildContext context) {
    if (_image == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        painter: _GrainPainter(_image!, widget.opacity),
        size: Size.infinite,
      ),
    );
  }
}

class _GrainPainter extends CustomPainter {
  final ui.Image tile;
  final double opacity;

  const _GrainPainter(this.tile, this.opacity);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // Shader strength must come from layer alpha
    canvas.saveLayer(
      rect,
      Paint()..color = const Color(0xFF000000).withValues(alpha: opacity),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.overlay
        ..shader = ImageShader(
          tile,
          TileMode.repeated,
          TileMode.repeated,
          Matrix4.identity().storage,
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GrainPainter old) =>
      old.tile != tile || old.opacity != opacity;
}
