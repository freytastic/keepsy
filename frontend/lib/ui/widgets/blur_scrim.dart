import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';

class BlurScrim extends StatelessWidget {
  final Animation<double> progress;
  final double sigma;
  final double saturation;
  final Color color;
  final VoidCallback? onTap;

  const BlurScrim({
    super.key,
    required this.progress,
    required this.color,
    this.sigma = Warm.peekBlur,
    this.saturation = Warm.peekSaturation,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Widget scrim = BackdropFilter(
      blendMode: BlendMode.src,
      filter: ui.ImageFilter.compose(
        outer: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        inner: ui.ColorFilter.matrix(Warm.saturation(saturation)),
      ),
      child: ColoredBox(color: color),
    );
    if (onTap != null) {
      scrim = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: scrim,
      );
    }
    return FadeTransition(opacity: progress, child: scrim);
  }
}
