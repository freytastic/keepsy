import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';

// ui element: orbs glowing in the background
class GlowOrbs extends StatefulWidget {
  final List<Color> colors;
  final double opacity;
  const GlowOrbs({super.key, required this.colors, this.opacity = 0.28});

  @override
  State<GlowOrbs> createState() => _GlowOrbsState();
}

class _GlowOrbsState extends State<GlowOrbs>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 10))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) {
        final t = _ctrl.value;
        return Stack(
          children: [
            _orb(
              color: widget.colors.isNotEmpty
                  ? widget.colors[0]
                  : const Color(0xFF667eea),
              left: -80 + t * 60,
              top: size.height * 0.05 + t * 40,
              size: 280,
              opacity: widget.opacity,
            ),
            _orb(
              color: widget.colors.length > 1
                  ? widget.colors[1]
                  : const Color(0xFF764ba2),
              right: -60 + (1 - t) * 40,
              top: size.height * 0.38 + t * 30,
              size: 220,
              opacity: widget.opacity * 0.85,
            ),
            _orb(
              color: widget.colors.length > 2
                  ? widget.colors[2]
                  : const Color(0xFFf093fb),
              left: size.width * 0.2 + t * 20,
              bottom: size.height * 0.12 + (1 - t) * 30,
              size: 170,
              opacity: widget.opacity * 0.7,
            ),
          ],
        );
      },
    );
  }

  Widget _orb({
    required Color color,
    required double size,
    required double opacity,
    double? left,
    double? right,
    double? top,
    double? bottom,
  }) {
    return Positioned(
      left: left,
      right: right,
      top: top,
      bottom: bottom,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [
            color.withOpacity(opacity),
            color.withOpacity(0),
          ]),
        ),
      ),
    );
  }
}

// primary button
class PrimaryButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  final bool loading;

  const PrimaryButton({
    super.key,
    required this.label,
    this.onTap,
    this.loading = false,
  });

  @override
  State<PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<PrimaryButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _shimmer;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
        vsync: this, duration: const Duration(seconds: 3))
      ..repeat();
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.watch<AppState>().accent;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap?.call();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedBuilder(
          animation: _shimmer,
          builder: (_, _) => Container(
            width: double.infinity,
            height: 56,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [accent, accent.withOpacity(0.75)],
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: accent.withOpacity(0.45),
                  blurRadius: 24,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: FractionalTranslation(
                      translation:
                      Offset(-1.5 + _shimmer.value * 3.0, 0),
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(colors: [
                            Colors.transparent,
                            Color(0x22FFFFFF),
                            Colors.transparent,
                          ]),
                        ),
                      ),
                    ),
                  ),
                  Center(
                    child: widget.loading
                        ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2),
                    )
                        : Text(
                      widget.label,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

