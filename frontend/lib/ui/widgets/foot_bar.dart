import 'package:flutter/material.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';

class FootScrim extends StatelessWidget {
  final double height;

  const FootScrim({super.key, required this.height});

  static const _fade = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0x00F6F3EE),
      Color(0x80F6F3EE),
      Color(0xE6F6F3EE),
      Warm.ground,
      Warm.ground,
    ],
    stops: [0, 0.26, 0.5, 0.66, 1],
  );

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: const DecoratedBox(
            decoration: BoxDecoration(gradient: _fade),
          ),
        ),
      );
}

class MakeButton extends StatefulWidget {
  final VoidCallback? onTap;
  final String? tooltip;

  const MakeButton({super.key, required this.onTap, this.tooltip});

  @override
  State<MakeButton> createState() => _MakeButtonState();
}

class _MakeButtonState extends State<MakeButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final button = GestureDetector(
      onTapDown:
          widget.onTap == null ? null : (_) => setState(() => _pressed = true),
      onTapUp: widget.onTap == null
          ? null
          : (_) {
              setState(() => _pressed = false);
              widget.onTap!();
            },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1,
        duration: Warm.quick,
        curve: Warm.easeOut,
        child: SizedBox(
          width: 58,
          height: 58,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: AnimatedOpacity(
                  opacity: _pressed ? 1 : 0.45,
                  duration: Warm.quick,
                  child: const _MakeGlow(),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: Warm.ctaFill,
                  shape: BoxShape.circle,
                  boxShadow: Warm.ctaShadow,
                ),
                child: SizedBox(
                  width: 58,
                  height: 58,
                  child: Icon(Icons.add_rounded,
                      size: 21,
                      color: widget.onTap == null
                          ? Warm.ctaInk.withValues(alpha: 0.45)
                          : Warm.ctaInk),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final label = widget.tooltip;
    return label == null ? button : Tooltip(message: label, child: button);
  }
}

class _MakeGlow extends StatelessWidget {
  const _MakeGlow();

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _GlowPainter());
}

class _GlowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = size.width * 0.84;
    final paint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
      ..shader = RadialGradient(
        colors: [
          Warm.orbPeach.withValues(alpha: 0.6),
          Warm.orbBlush.withValues(alpha: 0.3),
          Warm.orbPeach.withValues(alpha: 0),
        ],
        stops: const [0, 0.45, 0.72],
      ).createShader(Rect.fromCircle(center: centre, radius: radius));
    canvas.drawCircle(centre, radius, paint);
  }

  @override
  bool shouldRepaint(_GlowPainter old) => false;
}
