import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/pressable_scale.dart';

// The one primary button: lit face, top sheen, warm glow that brightens on press
class WarmButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  final bool busy;
  final bool small;
  final double? width;

  const WarmButton({
    super.key,
    required this.label,
    required this.onTap,
    this.busy = false,
    this.small = false,
    this.width,
  });

  @override
  State<WarmButton> createState() => _WarmButtonState();
}

class _WarmButtonState extends State<WarmButton> {
  bool _pressed = false;

  bool get _enabled => widget.onTap != null && !widget.busy;

  void _press(bool down) {
    if (_pressed != down) setState(() => _pressed = down);
  }

  @override
  Widget build(BuildContext context) {
    final height = widget.small ? 40.0 : Warm.ctaHeight;
    final radius = height / 2;
    final enabled = _enabled;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _press(true) : null,
      onTapCancel: enabled ? () => _press(false) : null,
      onTapUp: enabled ? (_) => _press(false) : null,
      onTap: enabled
          ? () {
              HapticFeedback.lightImpact();
              widget.onTap!();
            }
          : null,
      child: AnimatedOpacity(
        opacity: enabled || widget.busy ? 1 : 0.42,
        duration: Warm.quick,
        child: AnimatedScale(
          scale: _pressed ? 0.965 : 1,
          duration: Warm.quick,
          curve: Warm.easeOut,
          child: SizedBox(
            width: widget.width,
            height: height,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Container(
                  padding:
                      EdgeInsets.symmetric(horizontal: widget.small ? 18 : 24),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: Warm.ctaFill,
                    borderRadius: BorderRadius.circular(radius),
                    boxShadow: enabled ? Warm.ctaShadow : Warm.ctaShadowIdle,
                  ),
                  child: widget.busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Warm.ctaInk),
                        )
                      : AnimatedSwitcher(
                          duration: Warm.quick,
                          child: Text(
                            widget.label,
                            key: ValueKey(widget.label),
                            maxLines: 1,
                            style: widget.small
                                ? Warm.ctaLabel.copyWith(fontSize: 13.5)
                                : Warm.ctaLabel,
                          ),
                        ),
                ),
                Positioned.fill(child: WarmGlow(lit: _pressed, radius: radius)),
                Positioned(
                  top: 1,
                  left: 1,
                  right: 1,
                  height: height * 0.4,
                  child: IgnorePointer(child: WarmSheen(radius: radius)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WarmSheen extends StatelessWidget {
  final double radius;

  const WarmSheen({super.key, required this.radius});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(radius - 1),
          bottom: Radius.elliptical(radius, 12),
        ),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.07),
            Colors.white.withValues(alpha: 0),
          ],
        ),
      ),
    );
  }
}

// Painted over the dark face, which is what warms it to brown
class WarmGlow extends StatelessWidget {
  final bool lit;
  final double radius;

  const WarmGlow({super.key, required this.lit, required this.radius});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: lit ? 1 : 0.37,
          duration: Warm.quick,
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  // Expand the short-side radius across the wide pill
                  radius: 2.4,
                  colors: [
                    Warm.orbPeach.withValues(alpha: 0.55),
                    Warm.orbBlush.withValues(alpha: 0.28),
                    Warm.orbPeach.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.45, 0.72],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Secondary actions sit beside or under a WarmButton as words
class WarmTextButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final Color color;

  const WarmTextButton({
    super.key,
    required this.label,
    required this.onTap,
    this.color = Warm.inkSoft,
  });

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: Warm.textAction
              .copyWith(color: onTap == null ? Warm.inkFaint : color),
        ),
      ),
    );
  }
}

// Bare header chevron, the same weight as the album's
class WarmBack extends StatelessWidget {
  final VoidCallback? onTap;

  const WarmBack({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Back',
      child: PressableScale(
        onTap: onTap ?? () => Navigator.of(context).maybePop(),
        child: const SizedBox(
          width: 40,
          height: 40,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Icon(Icons.chevron_left_rounded, size: 28, color: Warm.ink),
          ),
        ),
      ),
    );
  }
}
