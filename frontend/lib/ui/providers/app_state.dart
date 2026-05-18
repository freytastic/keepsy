import 'dart:async';
import 'package:flutter/material.dart';
import 'package:keepsy/data/api/realtime_service.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/storage/storage_service.dart';
import 'package:keepsy/ui/theme/app_theme.dart';

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

  // Per album sync state : album IDs whose MK install is still in flight
  // (catchUpAll on cold start, or a wsreconnect replay). Album detail
  // screens should render a "syncing keys" placeholder while their id is in
  // this set instead of trying to decrypt and failing
  final Set<String> _syncing = {};
  bool isSyncing(String albumId) => _syncing.contains(albumId);

  void markSyncing(Iterable<String> ids) {
    if (ids.isEmpty) return;
    _syncing.addAll(ids);
    notifyListeners();
  }

  void clearSyncing(String id) {
    if (_syncing.remove(id)) notifyListeners();
  }

  void clearAllSyncing() {
    if (_syncing.isEmpty) return;
    _syncing.clear();
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
    // Email intentionally absent : server stores email_hmac per M8 privacy
    // audit, never the plaintext. Client owns its own email cache via
    // StorageService.saveEmail and pushes it via setEmail()
    // Name + avatar absent for the same reason (M7) : name lives encrypted
    // per album in album_members.name_ct, client caches its own typed name
    // via StorageService.saveName + setProfileName
    _userId = data['id'];

    if (data['accent_color'] != null) {
      _accent = K.hexColor(data['accent_color']);
    }
    if (data['theme'] != null) {
      _isDark = data['theme'] == 'dark';
    }
    notifyListeners();
  }

  void setEmail(String? email) {
    _email = email;
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
    // Persist locally so the profile screen still shows the right name on
    // next cold start. Per album name_ct publishing wires up in Phase 5
    unawaited(StorageService().saveName(name));
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
