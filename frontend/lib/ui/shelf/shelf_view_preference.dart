import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shelf_layout.dart';

// Loaded before the first frame; contains no album or person identifiers
class ShelfViewPreference extends ChangeNotifier {
  static const String _key = 'keepsy.shelf_view';

  final SharedPreferences _prefs;
  ShelfView _view;

  ShelfViewPreference._(this._prefs, this._view);

  static Future<ShelfViewPreference> load(SharedPreferences prefs) async {
    // Stored as a word, not an enum index, so reordering the enum can never
    // flip someone's layout
    final view = switch (prefs.getString(_key)) {
      'compact' => ShelfView.compact,
      _ => ShelfView.stacked,
    };
    return ShelfViewPreference._(prefs, view);
  }

  ShelfView get view => _view;

  Future<void> set(ShelfView next) async {
    if (next == _view) return;
    _view = next;
    notifyListeners();
    try {
      await _prefs.setString(
          _key, next == ShelfView.compact ? 'compact' : 'stacked');
    } catch (_) {
      // The layout still changes for this session
    }
  }
}
