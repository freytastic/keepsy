import 'package:flutter/material.dart';
import '../core/app_theme.dart';
import '../models/album_model.dart';

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

  List<AlbumModel> _albums = [];
  List<AlbumModel> get albums => _albums;

  void setAlbums(List<AlbumModel> newAlbums) {
    _albums = newAlbums;
    notifyListeners();
  }

  String? _userId;
  String? _email;
  String? _avatarKey;
  String _profileName = 'User';

  String? get userId => _userId;
  String? get email => _email;
  String? get avatarKey => _avatarKey;
  String get profileName => _profileName;

  // forward proxy for the avatar explicit URL 
  String? get avatarUrl => _avatarKey;

  void setUserData(Map<String, dynamic> data) {
    _userId = data['id'];
    _email = data['email'];
    _profileName = data['name'] ?? 'User';
    _avatarKey = data['avatar_key'];
    
    if (data['accent_color'] != null) {
      _accent = K.hexColor(data['accent_color']);
    }
    if (data['theme'] != null) {
      _isDark = data['theme'] == 'dark';
    }
    notifyListeners();
  }

  void setAccent(Color c) {
    _accent = c;
    notifyListeners();
  }

  void setTheme(bool dark) {
    _isDark = dark;
    notifyListeners();
  }
  
  void setProfileName(String name) {
    _profileName = name;
    notifyListeners();
  }

  void setProfileAvatar(String url) {
    _avatarKey = url;
    notifyListeners();
  }
}