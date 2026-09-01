import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';

// Stable hashing keeps card tilt fixed across launches
int fnv1a32(String s) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(s)) {
    h ^= b;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

double tiltFor(String albumId, {bool small = false}) {
  final t = (fnv1a32(albumId) % 89) / 89 * 4.4 - 2.2;
  return small ? t * 0.55 : t;
}

int edgesFor(int mediaCount) =>
    mediaCount >= 20 ? 2 : (mediaCount >= 4 ? 1 : 0);

Color hueFor(String memberToken) =>
    Warm.orbPalette[fnv1a32(memberToken) % Warm.orbPalette.length];
