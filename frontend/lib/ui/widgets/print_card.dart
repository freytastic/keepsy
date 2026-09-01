import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';

class PrintCard extends StatelessWidget {
  final Widget? well;
  final Widget? chin;

  // Zero is undeveloped and one is fully developed
  final Animation<double>? develop;

  final bool blank;

  final bool frame;

  final List<BoxShadow>? shadow;

  const PrintCard({
    super.key,
    this.well,
    this.chin,
    this.develop,
    this.blank = false,
    this.frame = false,
    this.shadow,
  });

  static const double _aspect = 300 / 372;
  static const double _padRatio = 1 / 15;
  static const double _wellAspect = 260 / 278;
  static const double _chinPadRatio = 0.037;

  @override
  Widget build(BuildContext context) {
    final card = DecoratedBox(
      decoration: BoxDecoration(
        color: Warm.paper,
        borderRadius: BorderRadius.circular(8),
        boxShadow: shadow ?? Warm.printShadow,
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          final pad = c.maxWidth * _padRatio;
          final wellWidth = c.maxWidth - pad * 2;
          return Padding(
            padding: EdgeInsets.only(left: pad, right: pad, top: pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  key: const ValueKey('print-well'),
                  height: wellWidth / _wellAspect,
                  child: _Well(develop: develop, blank: blank, child: well),
                ),
                if (chin != null)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(top: wellWidth * _chinPadRatio),
                      child: chin,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );

    return frame ? AspectRatio(aspectRatio: _aspect, child: card) : card;
  }
}

class _Well extends StatelessWidget {
  final Widget? child;
  final Animation<double>? develop;
  final bool blank;

  const _Well({this.develop, required this.blank, this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: blank ? null : Warm.wellEmpty,
              gradient: blank ? Warm.blankWellFill : null,
            ),
          ),
          if (child != null) child!,
          if (develop != null) _Emulsion(develop: develop!),
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.fromBorderSide(
                  BorderSide(color: Color(0x1A1E1610)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Matches the camera canvas develop wash
class _Emulsion extends StatelessWidget {
  final Animation<double> develop;

  const _Emulsion({required this.develop});

  static const Color _cream = Color(0xFFFDFBF6);
  static const Color _haze = Color(0xFFF0EBE1);

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: develop,
        builder: (context, _) {
          final v = develop.value.clamp(0.0, 1.0);
          final inverse = 1 - v;
          return CustomPaint(
            painter: _EmulsionPainter(
              cream: 0.94 * _pow(inverse, 1.1),
              haze: 0.25 * inverse * inverse,
            ),
          );
        },
      ),
    );
  }

  static double _pow(double base, double exp) =>
      base <= 0 ? 0 : math.pow(base, exp).toDouble();
}

class _EmulsionPainter extends CustomPainter {
  final double cream;
  final double haze;

  const _EmulsionPainter({required this.cream, required this.haze});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (cream > 0) {
      canvas.drawRect(
          rect, Paint()..color = _Emulsion._cream.withValues(alpha: cream));
    }
    if (haze > 0) {
      canvas.drawRect(
          rect, Paint()..color = _Emulsion._haze.withValues(alpha: haze));
    }
  }

  @override
  bool shouldRepaint(_EmulsionPainter old) =>
      old.cream != cream || old.haze != haze;
}
