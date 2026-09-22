import 'package:flutter/material.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/pressable_scale.dart';

import 'activity_copy.dart';

class ActivityCard extends StatelessWidget {
  final CardCopy copy;
  final bool alarm;
  final Widget face;
  final VoidCallback onGo;
  final VoidCallback onQuiet;

  const ActivityCard({
    super.key,
    required this.copy,
    required this.alarm,
    required this.face,
    required this.onGo,
    required this.onQuiet,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(17),
        gradient: Warm.acStoneFill,
        boxShadow: [
          BoxShadow(
              color: Warm.shadow(0.06),
              blurRadius: 2,
              offset: const Offset(0, 1)),
          BoxShadow(
              color: Warm.shadow(0.06),
              blurRadius: 16,
              offset: const Offset(0, 6)),
          BoxShadow(
              color: Warm.shadow(0.05),
              blurRadius: 34,
              offset: const Offset(0, 14)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: Stack(
          children: [
            const LitEdge(),
            if (alarm)
              const Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 3,
                child: ColoredBox(color: Warm.warn),
              ),
            Padding(
              // 15 at the foot visually, 5 of it inside the buttons' tap area
              padding: EdgeInsets.fromLTRB(alarm ? 20 : 17, 16, 17, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      face,
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(copy.title, style: Warm.acCardTitle),
                            const SizedBox(height: 2),
                            Text(copy.where, style: Warm.acWhere),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(copy.body, style: Warm.acCardBody),
                  // 14 visually: the buttons carry 5 of it as tap area
                  const SizedBox(height: 9),
                  Row(
                    children: [
                      _Btn(label: copy.go, primary: true, onTap: onGo),
                      if (copy.quiet != null) ...[
                        const SizedBox(width: 8),
                        _Btn(
                            label: copy.quiet!, primary: false, onTap: onQuiet),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Simulates the inset highlight Flutter's shadows cannot express
class LitEdge extends StatelessWidget {
  const LitEdge({super.key});

  @override
  Widget build(BuildContext context) {
    return const Positioned(
      left: 0,
      right: 0,
      top: 0,
      height: 1,
      child: ColoredBox(color: Color(0xE6FFFFFF)),
    );
  }
}

class _Btn extends StatelessWidget {
  final String label;
  final bool primary;
  final VoidCallback onTap;
  const _Btn({required this.label, required this.primary, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      haptic: true,
      // 48 high to tap, 38 high to look at
      child: SizedBox(
        key: ValueKey('card-$label'),
        height: 48,
        child: Center(
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 17),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(19),
              gradient: primary ? Warm.ctaFill : null,
              color: primary ? null : const Color(0x0E1C1917),
              boxShadow: primary
                  ? [
                      BoxShadow(
                          color: Warm.shadow(0.12),
                          blurRadius: 8,
                          offset: const Offset(0, 2)),
                    ]
                  : null,
            ),
            child: Text(label, style: primary ? Warm.acBtnGo : Warm.acBtnQuiet),
          ),
        ),
      ),
    );
  }
}
