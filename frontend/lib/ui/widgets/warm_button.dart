import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';

class WarmButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  final bool busy;

  const WarmButton({
    super.key,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  @override
  State<WarmButton> createState() => _WarmButtonState();
}

class _WarmButtonState extends State<WarmButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null && !widget.busy;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      onTap: enabled
          ? () {
              setState(() => _pressed = false);
              HapticFeedback.lightImpact();
              widget.onTap!();
            }
          : null,
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.42,
        duration: Warm.quick,
        child: AnimatedScale(
          scale: _pressed ? 0.965 : 1,
          duration: Warm.quick,
          curve: Warm.easeOut,
          child: Container(
            height: Warm.ctaHeight,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: Warm.ctaFill,
              borderRadius: BorderRadius.circular(Warm.ctaRadius),
              boxShadow: enabled ? Warm.ctaShadow : Warm.ctaShadowIdle,
            ),
            child: widget.busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Warm.ctaInk),
                  )
                : Text(widget.label, style: Warm.ctaLabel),
          ),
        ),
      ),
    );
  }
}
