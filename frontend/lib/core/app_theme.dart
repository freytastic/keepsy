import 'package:flutter/material.dart';

class K {
  // Palette
  static const Color black = Color(0xFF000000);
  static const Color surface1 = Color(0xFF0D0D0F);
  static const Color surface2 = Color(0xFF141416);
  static const Color card = Color(0xFF1C1C1F);
  static const Color cardHover = Color(0xFF242428);
  static const Color border = Color(0x22FFFFFF);
  static const Color borderMed = Color(0x33FFFFFF);

  static const Color defaultAccent = Color(0xFF2DD4BF);

  static const List<Color> accentOptions = [
    Color(0xFF2DD4BF),
    Color(0xFF818CF8),
    Color(0xFFF472B6),
    Color(0xFFFBBF24),
    Color(0xFF34D399),
    Color(0xFFF87171),
  ];

  static const List<List<String>> gradientPresets = [
    ['#ef32d9', '#89fffd'],
    ['#4ECDC4', '#556270'],
    ['#ffd89b', '#19547b'],
    ['#fceabb', '#f8b500'],
    ['#f85032', '#e73827'],
    ['#56ab2f', '#a8e063'],
    ['#000428', '#004e92'],
    ['#2196f3', '#f44336'],
  ];

  static const List<String> emojiOptions = [
    '📷', '🏖️', '⛰️', '🌃', '🎂', '🍽️', '🎓', '✈️',
    '🎵', '🌿', '🐶', '❤️', '🌸', '🎉', '🏡', '🌙',
    '🎬', '🏋️', '🎨', '🌊', '🦋', '🍕', '🚀', '💫',
  ];

  static List<Color> gradColors(List<String> hexes) =>
      hexes.map(hexColor).toList();

  static Color hexColor(String hex) {
    final h = hex.replaceAll('#', '');
    return Color(int.parse('FF$h', radix: 16));
  }

  // Text
  static Color t1(bool dark) => dark ? Colors.white : const Color(0xFF0D0D0F);
  static Color t2(bool dark) =>
      dark ? Colors.white.withOpacity(0.55) : Colors.black.withOpacity(0.55);
  static Color t3(bool dark) =>
      dark ? Colors.white.withOpacity(0.28) : Colors.black.withOpacity(0.28);

  // Surfaces
  static Color bg(bool dark) => dark ? black : const Color(0xFFF5F5F7);
  static Color cardCol(bool dark) =>
      dark ? card : Colors.white;
  static Color borderCol(bool dark) =>
      dark ? border : Colors.black.withOpacity(0.08);
  static Color glassCol(bool dark) =>
      dark ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.04);

  static ThemeData theme(bool dark, Color accent) {
    return ThemeData(
      brightness: dark ? Brightness.dark : Brightness.light,
      scaffoldBackgroundColor: bg(dark),
      colorScheme: dark
          ? ColorScheme.dark(primary: accent, surface: surface1)
          : ColorScheme.light(primary: accent, surface: Colors.white),
      useMaterial3: true,
      fontFamily: 'SF Pro Display',
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );
  }
}