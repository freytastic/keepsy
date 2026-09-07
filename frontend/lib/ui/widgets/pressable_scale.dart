import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';

// Scale feedback for controls without ink effects
class PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final bool haptic;

  const PressableScale({
    super.key,
    required this.child,
    required this.onTap,
    this.haptic = false,
  });

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  bool get _enabled => widget.onTap != null;

  void _set(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _enabled ? (_) => _set(true) : null,
      onTapCancel: _enabled ? () => _set(false) : null,
      onTapUp: _enabled ? (_) => _set(false) : null,
      onTap: _enabled
          ? () {
              if (widget.haptic) HapticFeedback.lightImpact();
              widget.onTap!();
            }
          : null,
      child: AnimatedScale(
        scale: _pressed ? Warm.pressScale : 1,
        duration: Warm.quick,
        curve: Warm.easeOut,
        child: widget.child,
      ),
    );
  }
}
