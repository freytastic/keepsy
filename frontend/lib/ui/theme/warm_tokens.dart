import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  static const Color stoneTopPressed = Color(0xFFF6F3ED);
  static const Color stoneBottomPressed = Color(0xFFE8E3DA);

  static const Color warn = Color(0xFF8C5A4A);

  static const Color paper = Color(0xFFFDFAF4);
  static const Color wellEmpty = Color(0xFFECE6DC);
  static const Color wellBlankTop = Color(0xFFF8F3EA);
  static const Color wellBlankBottom = Color(0xFFEFE9DD);

  static const Color orbBlush = Color(0xFFF4C7BF);
  static const Color orbPeach = Color(0xFFF6D2AB);
  static const Color orbGold = Color(0xFFF0DFA9);
  static const Color orbSage = Color(0xFFCFE0C6);
  static const Color orbPeri = Color(0xFFC6D4EC);
  static const Color orbClay = Color(0xFFE9CDBE);

  static const List<Color> orbPalette = [
    orbBlush,
    orbPeach,
    orbGold,
    orbSage,
    orbPeri,
    orbClay,
  ];

  static const Color ctaTop = Color(0xFF2A2622);
  static const Color ctaBottom = Color(0xFF17130F);
  static const Color ctaInk = Color(0xFFF7F3EC);

  static ThemeData get theme => ThemeData(
        brightness: Brightness.light,
        useMaterial3: true,
        fontFamily: fontFamily,
        scaffoldBackgroundColor: ground,
        colorScheme: const ColorScheme.light(
          primary: ctaTop,
          onPrimary: ctaInk,
          secondary: warn,
          surface: ground,
          onSurface: ink,
          error: warn,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: ground,
          foregroundColor: ink,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          systemOverlayStyle: overlayOnGround,
        ),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
      );

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

  static List<BoxShadow> get printShadow => [
        BoxShadow(
            color: shadow(0.05), blurRadius: 1.5, offset: const Offset(0, 1)),
        BoxShadow(
            color: shadow(0.05), blurRadius: 6, offset: const Offset(0, 3)),
        BoxShadow(
            color: shadow(0.055), blurRadius: 16, offset: const Offset(0, 8)),
        BoxShadow(
            color: shadow(0.06), blurRadius: 36, offset: const Offset(0, 18)),
        BoxShadow(
            color: shadow(0.07), blurRadius: 64, offset: const Offset(0, 34)),
      ];

  static List<BoxShadow> get printShadowBack => [
        BoxShadow(
            color: shadow(0.05), blurRadius: 2, offset: const Offset(0, 1)),
        BoxShadow(
            color: shadow(0.05), blurRadius: 14, offset: const Offset(0, 6)),
        BoxShadow(
            color: shadow(0.05), blurRadius: 30, offset: const Offset(0, 16)),
      ];

  static List<BoxShadow> get printShadowSmall => [
        BoxShadow(
            color: shadow(0.05), blurRadius: 1.5, offset: const Offset(0, 1)),
        BoxShadow(
            color: shadow(0.05), blurRadius: 7, offset: const Offset(0, 3)),
        BoxShadow(
            color: shadow(0.06), blurRadius: 18, offset: const Offset(0, 9)),
        BoxShadow(
            color: shadow(0.06), blurRadius: 34, offset: const Offset(0, 18)),
      ];

  static List<BoxShadow> get avatarShadow => [
        BoxShadow(
            color: shadow(0.07), blurRadius: 2, offset: const Offset(0, 1)),
        BoxShadow(
            color: shadow(0.06), blurRadius: 10, offset: const Offset(0, 4)),
      ];

  static List<BoxShadow> get sheetShadow => [
        BoxShadow(
            color: shadow(0.06), blurRadius: 6, offset: const Offset(2, 0)),
        BoxShadow(
            color: shadow(0.10), blurRadius: 44, offset: const Offset(18, 0)),
      ];

  static const LinearGradient fieldFill = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFFFFEFC), Color(0xFFF4F0E9)],
  );

  static const LinearGradient blankWellFill = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [wellBlankTop, wellBlankBottom],
  );

  // Typography
  // Preserve exact reference weights through the variable font axis
  static const String fontFamily = 'Inter';

  static TextStyle _t(
    double size,
    int weight, {
    double? letterSpacing,
    double? height,
    Color color = ink,
    List<FontFeature>? features,
  }) =>
      TextStyle(
        fontFamily: fontFamily,
        fontSize: size,
        fontWeight: FontWeight.values[(weight ~/ 100).clamp(1, 9) - 1],
        fontVariations: [FontVariation('wght', weight.toDouble())],
        letterSpacing: letterSpacing,
        height: height,
        color: color,
        fontFeatures: features,
      );

  // Shelf
  static TextStyle get h1 => _t(29, 600, letterSpacing: -0.87, height: 1.1);
  static TextStyle get sub =>
      _t(13.5, 400, letterSpacing: -0.027, color: inkSoft);
  static TextStyle get cardTitle => _t(17, 600, letterSpacing: -0.204);
  static TextStyle get cardTitleSmall => _t(12.5, 600, letterSpacing: -0.075);
  static TextStyle get meta => _t(12.5, 450, color: inkSoft);
  static TextStyle get metaNew => _t(12.5, 620, color: warn);
  static TextStyle get faceInitial => _t(10, 640, color: Color(0x9E1C1917));
  static TextStyle get tab =>
      _t(13, 560, letterSpacing: 0.052, color: inkFaint);
  static TextStyle get avatarInitial => _t(14, 600, color: inkSoft);

  static TextStyle get sectionLabel =>
      _t(10, 600, letterSpacing: 0.85, color: inkFaint);

  // Profile
  static TextStyle get printName => _t(15, 600, letterSpacing: -0.15);
  static TextStyle get rowTitle => _t(15, 560, letterSpacing: -0.12);
  static TextStyle get rowValue => _t(13, 460, color: inkSoft);
  static TextStyle get note =>
      _t(13, 400, letterSpacing: -0.026, height: 1.5, color: inkSoft);
  static TextStyle get factTitle =>
      _t(15, 600, letterSpacing: -0.18, height: 1.32);
  static TextStyle get link =>
      _t(13, 520, letterSpacing: -0.026, color: inkSoft);
  static TextStyle get idLabel => _t(13, 520, color: inkSoft);
  static TextStyle get idValue => _t(14.5, 600,
      letterSpacing: 1.015, features: const [FontFeature.tabularFigures()]);
  static TextStyle get version => _t(12, 450, color: inkFaint);

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

  // Each route must set dark icons against the cream background
  static const SystemUiOverlayStyle overlayOnGround = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemNavigationBarColor: ground,
    systemNavigationBarIconBrightness: Brightness.dark,
  );

  static const SystemUiOverlayStyle overlayOnPeek = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
  );

  // Motion
  // Wash exponents shape the linear develop progress
  static const Duration develop = Duration(milliseconds: 1300);
  static const Duration cardStagger = Duration(milliseconds: 70);
  static const Duration cardStaggerOffset = Duration(milliseconds: 60);

  static const Curve easeSoft = Cubic(0.16, 1, 0.3, 1);
  static const Curve easeOut = Cubic(0.22, 1, 0.36, 1);
  static const Duration quick = Duration(milliseconds: 200);
  static const Duration crossfade = Duration(milliseconds: 620);
  static const Duration springSoft = Duration(milliseconds: 760);
  static const Duration springSnappy = Duration(milliseconds: 320);

  // Scale feedback replaces disabled ink effects
  static const double pressScale = 0.96;

  // Warm glass keeps the shelf visible during album creation
  static const double glassBlur = 16;
  static const double glassSaturation = 0.92;
  static const Color glassScrim = Color(0x801E160F);
  static const Color glassInk = Color(0xFFFFFFFF);
  static const Color glassInkSoft = Color(0x75FFFFFF);
  static const Color glassInkFaint = Color(0x6BFFFFFF);
  static const Color glassFill = Color(0x21FFFFFF);
  static const Color glassHairline = Color(0x24FFFFFF);
  static const Color glassHairlineStrong = Color(0x38FFFFFF);
  // Raised warning color for the dark glass scrim
  static const Color warnGlass = Color(0xFFFFB4A6);

  static const double peekBlur = 18;
  static const double peekSaturation = 0.9;
  static const Color peekScrim = Color(0x85181410);

  // Luminance preserving saturation matrix
  static List<double> saturation(double s) {
    const rw = 0.213, gw = 0.715, bw = 0.072;
    final sr = (1 - s) * rw, sg = (1 - s) * gw, sb = (1 - s) * bw;
    return <double>[
      sr + s, sg, sb, 0, 0, //
      sr, sg + s, sb, 0, 0, //
      sr, sg, sb + s, 0, 0, //
      0, 0, 0, 1, 0,
    ];
  }
}
