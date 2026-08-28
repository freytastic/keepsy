import 'package:flutter/material.dart';

// Onboarding only design tokens
abstract class Warm {
  static const Color ground = Color(0xFFF6F3EE);
  static const Color groundLift = Color(0xFFFDFCFA);
  static const Color groundLift0 = Color(0x00FDFCFA);

  static const Color stoneTop = Color(0xFFFFFEFC);
  static const Color stoneBottom = Color(0xFFF4F0E9);

  static const Color ink = Color(0xFF1C1917);
  static const Color inkSoft = Color(0x801C1917);
  static const Color inkFaint = Color(0x421C1917);
  static const Color inkGhost = Color(0x211C1917);

  static const Color _sh = Color(0xFF201810);
  static Color shadow(double opacity) => _sh.withValues(alpha: opacity);

  static const Color orbBlush = Color(0xFFF4C7BF);
  static const Color orbPeach = Color(0xFFF6D2AB);

  static const Color ctaTop = Color(0xFF2A2622);
  static const Color ctaBottom = Color(0xFF17130F);
  static const Color ctaInk = Color(0xFFF7F3EC);

  // Form
  static const double ctaHeight = 56;
  static const double ctaRadius = 28;
  static const double fieldHeight = 58;
  static const double fieldRadius = 29;
  static const double otpCellWidth = 44;
  static const double otpCellHeight = 56;
  static const double otpCellRadius = 14;

  // Spacing
  static const double pagePad = 40;
  static const double topAir = 0.55;
  static const double headingToLead = 22;
  static const double leadMaxWidth = 304;
  static const double ctaBottomInset = 0.08;
  static const double dotsGap = 8;

  static const LinearGradient stoneFill = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [stoneTop, stoneBottom],
  );

  static const LinearGradient ctaFill = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [ctaTop, ctaBottom],
  );

  static List<BoxShadow> get ctaShadow => [
        BoxShadow(
            color: shadow(0.10), blurRadius: 2, offset: const Offset(0, 1)),
        BoxShadow(
            color: shadow(0.12), blurRadius: 18, offset: const Offset(0, 6)),
      ];

  static List<BoxShadow> get ctaShadowIdle => [
        BoxShadow(
            color: shadow(0.08), blurRadius: 2, offset: const Offset(0, 1)),
        BoxShadow(
            color: shadow(0.08), blurRadius: 10, offset: const Offset(0, 4)),
      ];

  static List<BoxShadow> get stoneShadow => [
        BoxShadow(
            color: shadow(0.04), blurRadius: 2, offset: const Offset(0, 1)),
      ];

  // Typography
  static const TextStyle wordmark = TextStyle(
    fontSize: 66,
    fontWeight: FontWeight.w700,
    letterSpacing: -1.45,
    height: 1,
    color: ink,
  );

  static const TextStyle lead = TextStyle(
    fontSize: 18.6,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.11,
    height: 1.46,
    color: inkSoft,
  );

  static const TextStyle trustMark = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.88,
    color: inkFaint,
  );

  static const TextStyle input = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.17,
    color: ink,
  );

  static const TextStyle otpDigit = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    height: 1,
    color: ink,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle ctaLabel = TextStyle(
    fontSize: 16.3,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.03,
    color: ctaInk,
  );

  static const TextStyle confirmTitle = TextStyle(
    fontSize: 25.6,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.51,
    color: ink,
  );

  static const TextStyle confirmSub = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    color: inkSoft,
  );

  // Motion
  static const Curve easeSoft = Cubic(0.16, 1, 0.3, 1);
  static const Curve easeOut = Cubic(0.22, 1, 0.36, 1);
  static const Duration quick = Duration(milliseconds: 200);
  static const Duration crossfade = Duration(milliseconds: 620);
  static const Duration springSoft = Duration(milliseconds: 760);
  static const Duration springSnappy = Duration(milliseconds: 320);
}
