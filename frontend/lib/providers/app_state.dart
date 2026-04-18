import 'package:flutter/material.dart';
import '../core/app_theme.dart';

class AppState extends ChangeNotifier {
  // only accent color for now cuz the login screen needs it
  Color _accent = K.defaultAccent;
  bool _isDark = true;
  bool _hasUnreadNotifications = false;

  Color get accent => _accent;
  bool get isDark => _isDark;
  bool get hasUnreadNotifications => _hasUnreadNotifications;

  void setUnreadNotifications(bool value) {
    _hasUnreadNotifications = value;
    notifyListeners();
  }

  // fix these later too
  final String _profileName = 'User';
  String get profileName => _profileName;

  void setAccent(Color c) {
    _accent = c;
    notifyListeners();
  }

  void setTheme(bool dark) {
    _isDark = dark;
    notifyListeners();
  }
  
}