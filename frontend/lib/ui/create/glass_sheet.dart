import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';

// Warm blurred overlay that keeps the shelf visible
class GlassSheet extends StatelessWidget {
  final Widget child;

  const GlassSheet({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        BackdropFilter(
          filter: ui.ImageFilter.compose(
            outer: ui.ImageFilter.blur(
                sigmaX: Warm.glassBlur, sigmaY: Warm.glassBlur),
            inner: ui.ColorFilter.matrix(_saturation(Warm.glassSaturation)),
          ),
          child: const ColoredBox(color: Warm.glassScrim),
        ),
        child,
      ],
    );
  }

  // Luminance preserving saturation matrix
  static List<double> _saturation(double s) {
    const rw = 0.213, gw = 0.715, bw = 0.072;
    final sr = (1 - s) * rw, sg = (1 - s) * gw, sb = (1 - s) * bw;
    return <double>[
      sr + s, sg, sb, 0, 0, //
      sr, sg + s, sb, 0, 0, //
      sr, sg, sb + s, 0, 0, //
      0, 0, 0, 1, 0,
    ];
  }
}
