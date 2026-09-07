import 'package:flutter/material.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/pressable_scale.dart';

class WarmButton extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final enabled = onTap != null && !busy;
    return PressableScale(
      onTap: enabled ? onTap : null,
      haptic: true,
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.42,
        duration: Warm.quick,
        child: Container(
          height: Warm.ctaHeight,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: Warm.ctaFill,
            borderRadius: BorderRadius.circular(Warm.ctaRadius),
            boxShadow: enabled ? Warm.ctaShadow : Warm.ctaShadowIdle,
          ),
          child: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Warm.ctaInk),
                )
              : Text(label, style: Warm.ctaLabel),
        ),
      ),
    );
  }
}
