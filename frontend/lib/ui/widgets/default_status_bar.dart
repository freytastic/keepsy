import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';

// Restores dark icons after a route-specific light-icon region disappears
class DefaultStatusBar extends StatelessWidget {
  final Widget child;
  const DefaultStatusBar({super.key, required this.child});

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: Warm.overlayOnGround,
        child: child,
      );
}
