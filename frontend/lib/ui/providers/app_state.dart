import 'dart:async';
import 'package:flutter/material.dart';
import 'package:keepsy/ui/theme/app_theme.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/api/realtime_service.dart';

class AppState extends ChangeNotifier {
  StreamSubscription<RealtimeEvent>? _realtimeSub;

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

  // Called after a successful login to start receiving push events.
  // Dispatchers are stubs , populated in Phase 4+ as E2EE protocol layers land
  void startRealtime(Stream<RealtimeEvent> events) {
    _realtimeSub?.cancel();
    _realtimeSub = events.listen(_onRealtimeEvent);
  }

  void _onRealtimeEvent(RealtimeEvent event) {
    // §4.2 e2ee.epoch_changed + §2.2 e2ee.opk_low both dispatched in main.dart
    // alongside the rest of the E2EE composition root. UI side stays a stub
    // for the manifest / membership events until p7 / p8 land
    switch (event.type) {
      case 'e2ee.manifest_updated': // todo (p8): re-verify manifest
      case 'e2ee.member_added': // todo (p7): refresh member list
      case 'e2ee.member_revoked': // todo (p7): refresh member list
        break;
    }
  }

  @override
  void dispose() {
    _realtimeSub?.cancel();
    super.dispose();
  }
}
