import 'package:flutter/widgets.dart';

// Keeps develop controllers stable across layout remounts
class DevelopStore {
  final TickerProvider vsync;
  final Duration duration;
  final Map<String, AnimationController> _by = {};
  final Map<String, int> _unseen = {};

  DevelopStore({required this.vsync, required this.duration});

  Animation<double> sync(String albumId, int unseen) {
    final held = _by[albumId];
    if (held == null) {
      _unseen[albumId] = unseen;
      return _by[albumId] = AnimationController(
        vsync: vsync,
        duration: duration,
        value: unseen > 0 ? 0 : 1,
      );
    }
    final was = _unseen[albumId];
    _unseen[albumId] = unseen;
    if (was == null || was == unseen) return held;
    // Newly unseen prints reset instead of reversing
    if (unseen == 0) {
      held.forward();
    } else if (was == 0) {
      held.value = 0;
    }
    return held;
  }

  Animation<double>? read(String albumId) => _by[albumId];

  void retain(Set<String> albumIds) {
    for (final id in _by.keys.toList()) {
      if (albumIds.contains(id)) continue;
      _by.remove(id)?.dispose();
      _unseen.remove(id);
    }
  }

  void dispose() {
    for (final c in _by.values) {
      c.dispose();
    }
    _by.clear();
    _unseen.clear();
  }
}
