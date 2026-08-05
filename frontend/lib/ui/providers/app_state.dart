import 'dart:async';

import 'package:flutter/material.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/api/realtime_service.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/storage/storage_service.dart';
import 'package:keepsy/e2ee/epoch_processor.dart';
import 'package:keepsy/ui/theme/app_theme.dart';

// Decrypts an album's name_ct to a display string. Injected at boot (main.dart)
// so AppState itself stays free of crypto/keystore deps
typedef AlbumNameResolver = Future<String> Function(
    String albumId, String? nameCt);

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

  // Decrypted album titles keyed by album id. Populated asynchronously by the
  // injected resolver : the UI reads this (with a placeholder fallback) rather
  // than the raw name_ct
  final Map<String, String> _albumNames = {};
  String? albumDisplayName(String id) => _albumNames[id];

  // nameCt we authored locally (create/rename PATCH) that the server may not
  // have echoed back yet. setAlbums/prependAlbum overlay it so a stale GET that
  // still carries the create time placeholder can't regress the title. Dropped
  // once the server returns the same nameCt
  final Map<String, String> _localNameCt = {};

  AlbumModel _overlayLocalNameCt(AlbumModel a) {
    final local = _localNameCt[a.id];
    if (local == null) return a;
    if (a.nameCt == local) {
      _localNameCt.remove(a.id); // server caught up
      return a;
    }
    return a.copyWith(nameCt: local); // incoming is an older placeholder
  }

  // Wipe the in RAM plaintext title cache (logout : the persistent NameCache is
  // cleared separately)
  void clearDisplayNameCaches() {
    _albumNames.clear();
    _localNameCt.clear();
    notifyListeners();
  }

  // Full session reset on logout : doesnt touch device bound E2EE key material
  void reset() {
    _realtimeSub?.cancel();
    _realtimeSub = null;
    _albums = [];
    _albumNames.clear();
    _localNameCt.clear();
    _syncing.clear();
    _keyBlocks.clear();
    _selfTokens.clear();
    _lastRemovedAlbumId = null;
    _hasUnreadNotifications = false;
    // realtime one-shot signals
    _lastMediaAddedAlbumId = null;
    _lastMediaAddedMediaId = null;
    _lastMemberChangedAlbumId = null;
    _memberChangeTick = 0;
    // identity + profile : must not bleed into the next account's session
    _userId = null;
    _email = null;
    _keepsyId = null;
    _avatarKey = null;
    _profileName = 'User';
    notifyListeners();
  }

  AlbumNameResolver? _nameResolver;
  void attachAlbumNameResolver(AlbumNameResolver r) {
    _nameResolver = r;
    refreshAlbumNames();
  }

  // Directly set a title we already hold in plaintext (eg  right after
  // creating an album) : skips a needless decrypt round trip
  void setAlbumDisplayName(String id, String name) {
    _albumNames[id] = name;
    notifyListeners();
  }

  // After sealing + PATCHing a new title, update BOTH the cached display name
  // and the stored album's raw nameCt. Without the nameCt update, _albums still
  // holds the create time placeholder, so a later refreshAlbumNames() would
  // re resolve that placeholder and clobber the correct title
  void applyAlbumNameCt(String id, String nameCt, String displayName) {
    _localNameCt[id] = nameCt;
    final i = _albums.indexWhere((a) => a.id == id);
    if (i != -1) {
      _albums[i] = _albums[i].copyWith(nameCt: nameCt);
    }
    _albumNames[id] = displayName;
    notifyListeners();
  }

  // Re resolve every album's title. Called after the resolver attaches and
  // again after key catch up installs the MKs (names sealed under a not yet
  // installed epoch resolve to a placeholder until then)
  void refreshAlbumNames() {
    for (final a in _albums) {
      unawaited(_resolveName(a));
    }
  }

  Future<void> _resolveName(AlbumModel a) async {
    final r = _nameResolver;
    if (r == null) return;
    final name = await r(a.id, a.nameCt);
    // Stale guard: if the album's nameCt changed while we were resolving (eg
    // applyAlbumNameCt landed the real title after a create PATCH, or setAlbums
    // replaced the row), discard this now stale result so it can't clobber the
    // newer name
    final idx = _albums.indexWhere((x) => x.id == a.id);
    if (idx == -1 || _albums[idx].nameCt != a.nameCt) return;
    if (_albumNames[a.id] != name) {
      _albumNames[a.id] = name;
      notifyListeners();
    }
  }

  void setAlbums(List<AlbumModel> newAlbums) {
    // Overlay any locally authored nameCt so a stale GET placeholder can't
    // regress a title we just PATCHed (create/rename)
    _albums = newAlbums.map(_overlayLocalNameCt).toList();
    for (final a in _albums) {
      final t = a.memberToken;
      if (t != null) _selfTokens[a.id] = t;
    }
    // A re invited album reappearing clears the stale "was removed" signal so an
    // AlbumDetailScreen opened for it doesnt trip the kicked-while-viewing exit
    if (_lastRemovedAlbumId != null &&
        newAlbums.any((x) => x.id == _lastRemovedAlbumId)) {
      _lastRemovedAlbumId = null;
    }
    notifyListeners();
    refreshAlbumNames();
  }

  // Insert a freshly joined album at the front of the home grid. Idempotent
  // by id : a duplicate signal (live event + cold-start replay) wont double
  // the tile
  void prependAlbum(AlbumModel a) {
    // Re invite to a previously kicked album: clear the stale removal signal so
    // the reopened detail screen doesnt auto exit (see removeAlbum below)
    if (_lastRemovedAlbumId == a.id) _lastRemovedAlbumId = null;
    if (_albums.any((x) => x.id == a.id)) return;
    final overlaid = _overlayLocalNameCt(a);
    final t = overlaid.memberToken;
    if (t != null) _selfTokens[overlaid.id] = t;
    _albums = [overlaid, ..._albums];
    notifyListeners();
    unawaited(_resolveName(overlaid));
  }

  // Drop an album from the home grid : used when this device is removed/leaves
  // an album (removed device wipe). Also records the id as the last removed
  // signal so an open AlbumDetailScreen for that album can exit itself instead
  // of showing stale content
  String? _lastRemovedAlbumId;
  String? get lastRemovedAlbumId => _lastRemovedAlbumId;

  void removeAlbum(String albumIdStr) {
    _albums = _albums.where((x) => x.id != albumIdStr).toList();
    _albumNames.remove(albumIdStr);
    _localNameCt.remove(albumIdStr);
    _keyBlocks.remove(albumIdStr);
    _selfTokens.remove(albumIdStr);
    _lastRemovedAlbumId = albumIdStr;
    notifyListeners();
  }

  Future<void> refreshAlbumOnJoin(
      String albumIdStr, AlbumService service) async {
    try {
      final a = await service.getAlbum(albumIdStr);
      if (a != null) {
        prependAlbum(a);
        return;
      }
      final all = await service.getMyAlbums();
      setAlbums(all);
    } catch (_) {}
  }

  // last (albumId, mediaId) seen on e2ee.media_added
  // AlbumDetailScreen watches AppState and re-runs _loadMedia when the
  // matching album_id arrives. Tuple is overwritten on each event : the
  // screen tracks last seen locally so it only reacts once per id
  String? _lastMediaAddedAlbumId;
  String? _lastMediaAddedMediaId;
  String? get lastMediaAddedAlbumId => _lastMediaAddedAlbumId;
  String? get lastMediaAddedMediaId => _lastMediaAddedMediaId;

  void notifyMediaAdded(String albumId, String mediaId) {
    _lastMediaAddedAlbumId = albumId;
    _lastMediaAddedMediaId = mediaId;
    notifyListeners();
  }

  // Roster change signal (member joined / revoked). An open AlbumDetailScreen
  // watches this and re fetches its member list. The tick lets the screen react
  // to repeated changes on the same album (album id alone wouldnt change)
  String? _lastMemberChangedAlbumId;
  int _memberChangeTick = 0;
  String? get lastMemberChangedAlbumId => _lastMemberChangedAlbumId;
  int get memberChangeTick => _memberChangeTick;

  void notifyMemberChanged(String albumId) {
    _lastMemberChangedAlbumId = albumId;
    _memberChangeTick++;
    notifyListeners();
  }

  // albumId -> MY member_token there. Kept separately from _albums bcs the
  // signer gate needs it the moment an album exists : the creator's own epoch 0
  // rotation fans back to them, and that can land before the album list has
  // refreshed. Without it their own wrap takes the peer path and is refused
  final Map<String, String> _selfTokens = {};
  String? selfMemberToken(String albumId) => _selfTokens[albumId];

  void registerSelfToken(String albumId, String memberTokenB64) {
    _selfTokens[albumId] = memberTokenB64;
  }

  // Durable per album key sync failures. Unlike in-flight _syncing state, a
  // block persists until a manual or background catch up reaches its epoch
  final Map<String, EpochBlocked> _keyBlocks = {};
  EpochBlocked? keyBlockFor(String albumId) => _keyBlocks[albumId];

  void setKeyBlock(String albumId, EpochBlocked block) {
    _keyBlocks[albumId] = block;
    notifyListeners();
  }

  // reachedEpoch is what the sync actually caught up TO. A delayed duplicate
  // event for an older epoch completes trivially (everything below it is
  // already installed) and would otherwise clear a block raised by a newer one
  // No ops silently: this fires after every successful sync, so the
  // overwhelmingly common call has nothing to announce
  void clearKeyBlock(String albumId, int reachedEpoch) {
    final block = _keyBlocks[albumId];
    if (block == null || reachedEpoch < block.epoch) return;
    _keyBlocks.remove(albumId);
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
  String? _keepsyId;
  String? _avatarKey;
  String _profileName = 'User';

  String? get userId => _userId;
  String? get email => _email;

  String? get keepsyId => _keepsyId;
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
    _keepsyId = data['keepsy_id'] as String?;

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
