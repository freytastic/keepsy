import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:keepsy/crypto/uuid_bytes.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/api/realtime_service.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/models/album_summary.dart';
import 'package:keepsy/data/models/avatar_ref.dart';
import 'package:keepsy/data/storage/storage_service.dart';
import 'package:keepsy/diagnostics/trace.dart';
import 'package:keepsy/e2ee/epoch_processor.dart';
import 'package:keepsy/e2ee/rotation_recovery.dart';

// Decrypts an album's name_ct to a display string. Injected at boot (main.dart)
// so AppState itself stays free of crypto/keystore deps
typedef AlbumNameResolver = Future<String> Function(
    String albumId, String? nameCt);

typedef MemberNameResolver = Future<String?> Function(
    String albumId, String memberToken, String? nameCt);

class AppState extends ChangeNotifier {
  final Duration summaryDebounce;
  StreamSubscription<RealtimeEvent>? _realtimeSub;

  bool _hasUnreadNotifications = false;

  AppState({this.summaryDebounce = const Duration(seconds: 2)});

  bool get hasUnreadNotifications => _hasUnreadNotifications;

  void setUnreadNotifications(bool value) {
    _hasUnreadNotifications = value;
    notifyListeners();
  }

  List<AlbumModel> _albums = [];
  List<AlbumModel> get albums => _albums;

  // The UI reads resolved titles here and never renders raw ciphertext
  final Map<String, String> _albumNames = {};
  String? albumDisplayName(String id) => _albumNames[id];

  // Prevents stale server reads from replacing a locally written title
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
    _memberNames.clear();
    notifyListeners();
  }

  // Full session reset on logout : doesnt touch device bound E2EE key material
  void reset() {
    _realtimeSub?.cancel();
    _realtimeSub = null;
    _albums = [];
    _albumNames.clear();
    _localNameCt.clear();
    _memberNames.clear();
    _syncing.clear();
    _keyBlocks.clear();
    _rotations.clear();
    _selfTokens.clear();
    _lastRemovedAlbumId = null;
    _hasUnreadNotifications = false;
    // realtime one-shot signals
    _lastMediaAddedAlbumId = null;
    _lastMediaAddedMediaId = null;
    _lastMemberChangedAlbumId = null;
    _memberChangeTick = 0;
    _lastMediaRemovedAlbumId = null;
    _mediaRemovedTick = 0;
    _deletedAlbums.clear();
    // identity + profile : must not bleed into the next account's session
    _userId = null;
    _email = null;
    _keepsyId = null;
    _profileName = 'User';
    notifyListeners();
  }

  AlbumNameResolver? _nameResolver;
  void attachAlbumNameResolver(AlbumNameResolver r) {
    _nameResolver = r;
    refreshAlbumNames();
  }

  // Album scoped keys let removal wipe member name plaintext
  final Map<String, String> _memberNames = {};
  static String _memberKey(String albumId, String memberToken) =>
      '$albumId|$memberToken';

  String? memberDisplayName(String albumId, String memberToken) =>
      _memberNames[_memberKey(albumId, memberToken)];

  MemberNameResolver? _memberNameResolver;
  void attachMemberNameResolver(MemberNameResolver r) {
    _memberNameResolver = r;
    refreshMemberNames();
  }

  void refreshMemberNames() {
    final r = _memberNameResolver;
    if (r == null) return;
    for (final a in _albums) {
      for (final m in a.memberPreviews) {
        if (m.nameCt == null) continue;
        unawaited(_resolveMemberName(a.id, m));
      }
    }
  }

  Future<void> _resolveMemberName(String albumId, MemberPreview m) async {
    final r = _memberNameResolver;
    if (r == null) return;
    final name = await r(albumId, m.memberToken, m.nameCt);
    if (name == null || name.isEmpty) return;
    // Do not restore plaintext after album removal
    if (!_albums.any((a) => a.id == albumId)) return;
    final key = _memberKey(albumId, m.memberToken);
    if (_memberNames[key] == name) return;
    _memberNames[key] = name;
    notifyListeners();
  }

  // Directly set a title we already hold in plaintext (eg  right after
  // creating an album) : skips a needless decrypt round trip
  void setAlbumDisplayName(String id, String name) {
    _albumNames[id] = name;
    notifyListeners();
  }

  // Update ciphertext and plaintext together so later resolution cannot regress
  void applyAlbumNameCt(String id, String nameCt, String displayName) {
    _localNameCt[id] = nameCt;
    final i = _albums.indexWhere((a) => a.id == id);
    if (i != -1) {
      _albums[i] = _albums[i].copyWith(nameCt: nameCt);
    }
    _albumNames[id] = displayName;
    _saveShelf();
    notifyListeners();
  }

  // Retry title resolution after missing MKs install
  void refreshAlbumNames() {
    for (final a in _albums) {
      unawaited(_resolveName(a));
    }
  }

  Future<void> _resolveName(AlbumModel a) async {
    final r = _nameResolver;
    if (r == null) return;
    final name = await r(a.id, a.nameCt);
    // A newer ciphertext invalidates this in-flight result
    final idx = _albums.indexWhere((x) => x.id == a.id);
    if (idx == -1 || _albums[idx].nameCt != a.nameCt) return;
    if (_albumNames[a.id] != name) {
      _albumNames[a.id] = name;
      notifyListeners();
    }
  }

  // Albums held here that an authoritative listing no longer returns
  void Function(List<String> albumIds)? _onAlbumsVanished;
  void attachAlbumsVanished(void Function(List<String> albumIds) f) =>
      _onAlbumsVanished = f;

  // Announces server listings without treating local restores as evidence
  void Function()? _onListingApplied;
  void attachListingApplied(void Function() f) => _onListingApplied = f;

  void applyListing(List<AlbumModel> listing) {
    setAlbums(listing);
    _onListingApplied?.call();
  }

  void setAlbums(List<AlbumModel> newAlbums) {
    final incoming = {for (final a in newAlbums) a.id};
    final vanished = [
      for (final a in _albums)
        if (!incoming.contains(a.id)) a.id,
    ];
    // Overlay any locally authored nameCt so a stale GET placeholder can't
    // regress a title me just PATCHed (create/rename)
    _albums = _mergeMonotonic(newAlbums.map(_overlayLocalNameCt).toList());
    for (final a in _albums) {
      final t = a.memberToken;
      if (t != null) _selfTokens[a.id] = t;
      if (a.rotationRequired && !_rotations.containsKey(a.id)) {
        _rotationPrompt?.call(a.id);
      }
    }
    _saveShelf();
    // A re invited album reappearing clears the stale "was removed" signal so an
    // AlbumDetailScreen opened for it doesnt trip the kicked-while-viewing exit
    if (_lastRemovedAlbumId != null &&
        newAlbums.any((x) => x.id == _lastRemovedAlbumId)) {
      _lastRemovedAlbumId = null;
    }
    notifyListeners();
    refreshAlbumNames();
    refreshMemberNames();
    if (vanished.isNotEmpty) _onAlbumsVanished?.call(vanished);
  }

  // Never replace a newer realtime summary with an older HTTP response
  List<AlbumModel> _mergeMonotonic(List<AlbumModel> incoming) {
    if (_albums.isEmpty) return incoming;
    final held = {for (final a in _albums) a.id: a};
    final order = {
      for (var i = 0; i < _albums.length; i++) _albums[i].id: i,
    };

    final ahead = <AlbumModel>[];
    final rest = <AlbumModel>[];
    for (final a in incoming) {
      final was = held[a.id];
      if (was == null ||
          !was.hasSummary ||
          !a.hasSummary ||
          a.mediaGeneration >= was.mediaGeneration) {
        rest.add(a);
        continue;
      }
      ahead.add(a.copyWith(
        mediaCount: was.mediaCount,
        mediaGeneration: was.mediaGeneration,
        latestActivityAt: was.latestActivityAt,
        previewMedia: was.previewMedia,
      ));
    }
    if (ahead.isEmpty) return incoming;
    ahead.sort(
        (x, y) => (order[x.id] ?? 1 << 30).compareTo(order[y.id] ?? 1 << 30));
    return [...ahead, ...rest];
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
    _saveShelf();
    notifyListeners();
    unawaited(_resolveName(overlaid));
  }

  // Records the loss so an open album can exit instead of showing stale content
  String? _lastRemovedAlbumId;
  String? get lastRemovedAlbumId => _lastRemovedAlbumId;

  void removeAlbum(String albumIdStr) {
    _albums = _albums.where((x) => x.id != albumIdStr).toList();
    _memberNames.removeWhere((k, _) => k.startsWith('$albumIdStr|'));
    _albumNames.remove(albumIdStr);
    _localNameCt.remove(albumIdStr);
    _keyBlocks.remove(albumIdStr);
    _rotations.remove(albumIdStr);
    _selfTokens.remove(albumIdStr);
    _lastRemovedAlbumId = albumIdStr;
    _saveShelf();
    notifyListeners();
  }

  // Prefer list data because single album responses lack shelf summaries
  Future<void> refreshAlbumOnJoin(
      String albumIdStr, AlbumService service) async {
    try {
      final all = await service.getMyAlbums();
      if (all != null) {
        applyListing(all);
        return;
      }
      final a = await service.getAlbum(albumIdStr);
      if (a != null) prependAlbum(a);
    } catch (_) {}
  }

  // Apply realtime generation and move the album to the front
  void applyMediaAdded(String albumIdStr, int generation,
      {PreviewMedia? preview}) {
    final i = _albums.indexWhere((a) => a.id == albumIdStr);
    if (i < 0) return;
    final a = _albums[i];
    if (generation <= a.mediaGeneration) return;

    // A generation gap requires authoritative summary data
    if (generation > a.mediaGeneration + 1) _scheduleSummaryRefresh();

    final nextPreview = preview == null
        ? a.previewMedia
        : [
            preview,
            ...a.previewMedia.where((p) => p.mediaId != preview.mediaId),
          ].take(3).toList();

    final moved = a.copyWith(
      mediaCount: a.mediaCount + (generation - a.mediaGeneration),
      mediaGeneration: generation,
      latestActivityAt: DateTime.now().toUtc(),
      previewMedia: nextPreview,
    );
    _albums = [moved, ..._albums]..removeAt(i + 1);
    _saveShelf();
    notifyListeners();
  }

  // Serialize writes so stale shelf snapshots cannot land last
  Future<void> Function(List<AlbumModel>)? _persistShelf;
  Future<void>? _persistInFlight;
  bool _persistAgain = false;

  void attachShelfPersistence(Future<void> Function(List<AlbumModel>) p) =>
      _persistShelf = p;

  void _saveShelf() {
    if (_persistShelf == null) return;
    if (_persistInFlight != null) {
      _persistAgain = true;
      return;
    }
    _persistInFlight = _drainShelf();
  }

  Future<void> _drainShelf() async {
    try {
      do {
        _persistAgain = false;
        try {
          await _persistShelf!(List<AlbumModel>.unmodifiable(_albums));
        } catch (_) {}
      } while (_persistAgain);
    } finally {
      _persistInFlight = null;
    }
  }

  Future<void> Function()? _summaryRefresh;
  Timer? _summaryDebounce;
  void attachSummaryRefresh(Future<void> Function() r) => _summaryRefresh = r;

  void refreshSummarySoon() => _scheduleSummaryRefresh();

  void _scheduleSummaryRefresh() {
    final r = _summaryRefresh;
    if (r == null) return;
    _summaryDebounce?.cancel();
    _summaryDebounce = Timer(summaryDebounce, () => unawaited(r()));
  }

  // Open albums track the last seen id to consume each media signal once
  String? _lastMediaAddedAlbumId;
  String? _lastMediaAddedMediaId;
  String? get lastMediaAddedAlbumId => _lastMediaAddedAlbumId;
  String? get lastMediaAddedMediaId => _lastMediaAddedMediaId;

  void notifyMediaAdded(String albumId, String mediaId) {
    _lastMediaAddedAlbumId = albumId;
    _lastMediaAddedMediaId = mediaId;
    notifyListeners();
  }

  // The tick distinguishes repeated roster changes on the same album
  String? _lastMemberChangedAlbumId;
  int _memberChangeTick = 0;
  String? get lastMemberChangedAlbumId => _lastMemberChangedAlbumId;
  int get memberChangeTick => _memberChangeTick;

  void notifyMemberChanged(String albumId) {
    _lastMemberChangedAlbumId = albumId;
    _memberChangeTick++;
    notifyListeners();
  }

  // Photos deleted elsewhere. An open album re lists so they disappear
  String? _lastMediaRemovedAlbumId;
  int _mediaRemovedTick = 0;
  String? get lastMediaRemovedAlbumId => _lastMediaRemovedAlbumId;
  int get mediaRemovedTick => _mediaRemovedTick;

  void notifyMediaRemoved(String albumId) {
    _lastMediaRemovedAlbumId = albumId;
    _mediaRemovedTick++;
    notifyListeners();
    _scheduleSummaryRefresh();
  }

  // Lets an open album tell deletion apart from removal
  final Set<String> _deletedAlbums = {};
  bool wasDeleted(String albumId) => _deletedAlbums.contains(albumId);
  void markAlbumDeleted(String albumId) => _deletedAlbums.add(albumId);

  // Kept outside album listings because epoch 0 may arrive before a refresh
  final Map<String, String> _selfTokens = {};
  String? selfMemberToken(String albumId) => _selfTokens[albumId];

  // What the latest listing shows for a member, so every face agrees
  AvatarRef? avatarOf(String albumId, String memberToken) {
    for (final a in _albums) {
      if (a.id != albumId) continue;
      for (final m in a.memberPreviews) {
        if (m.memberToken == memberToken) return m.avatar;
      }
    }
    return null;
  }

  void registerSelfToken(String albumId, String memberTokenB64) {
    _selfTokens[albumId] = memberTokenB64;
  }

  // Successful key installation is the only safe upload resume signal
  void Function(String albumId)? _onAlbumKeysReady;
  void attachUploadResume(void Function(String albumId) resume) =>
      _onAlbumKeysReady = resume;

  void _releaseUploads(String albumId) => _onAlbumKeysReady?.call(albumId);

  // Durable per album key sync failures. Unlike in-flight _syncing state, a
  // block persists until a manual or background catch up reaches its epoch
  final Map<String, EpochBlocked> _keyBlocks = {};
  EpochBlocked? keyBlockFor(String albumId) => _keyBlocks[albumId];

  void setKeyBlock(String albumId, EpochBlocked block) {
    _keyBlocks[albumId] = block;
    notifyListeners();
  }

  // An older completed sync must not clear a block raised by a newer epoch
  void clearKeyBlock(String albumId, int reachedEpoch) {
    final block = _keyBlocks[albumId];
    // Never resume a queue still blocked on a newer epoch
    if (block != null && reachedEpoch < block.epoch) return;
    // Pauses without key blocks also resume after a successful sync
    _releaseUploads(albumId);
    if (block == null) return;
    _keyBlocks.remove(albumId);
    notifyListeners();
  }

  bool isAdminOf(String albumId) {
    for (final a in _albums) {
      if (a.id == albumId) return a.myRole == 'admin';
    }
    return false;
  }

  // Albums owing a key rotation. Held until the scheduler reports it clear
  final Map<String, RotationStatus> _rotations = {};

  RotationStatus? rotationFor(String albumId) {
    final live = _rotations[albumId];
    if (live != null) return live;
    // The persisted summary shows the debt offline before any check runs
    for (final a in _albums) {
      if (a.id != albumId) continue;
      if (!a.rotationRequired) return null;
      final admin = a.myRole == 'admin';
      return RotationStatus(
        albumId: uuidToBytes(albumId) ?? Uint8List(0),
        phase: admin ? RotationPhase.failed : RotationPhase.waiting,
        failure: admin ? RotationFailure.unavailable : null,
      );
    }
    return null;
  }

  void setRotationStatus(String albumId, RotationStatus status) {
    final owed = status.phase != RotationPhase.clear;
    // A late report must not resurrect state for a removed album
    if (owed && !_albums.any((a) => a.id == albumId)) return;
    final changed = owed
        ? !identical(_rotations[albumId], status)
        : _rotations.remove(albumId) != null;
    if (owed) _rotations[albumId] = status;
    final flagged = _setRotationFlag(albumId, owed);
    if (changed || flagged) notifyListeners();
  }

  // Keeps the persisted summary in step with what the scheduler learned
  bool _setRotationFlag(String albumId, bool owed) {
    final i = _albums.indexWhere((a) => a.id == albumId);
    if (i < 0 || _albums[i].rotationRequired == owed) return false;
    _albums[i] = _albums[i].copyWith(rotationRequired: owed);
    _saveShelf();
    return true;
  }

  void Function(String albumId)? _rotationPrompt;
  void attachRotationPrompt(void Function(String albumId) prompt) =>
      _rotationPrompt = prompt;

  // Album screens wait while their MK installation is still in flight
  final Set<String> _syncing = {};
  bool isSyncing(String albumId) => _syncing.contains(albumId);

  void markSyncing(Iterable<String> ids) {
    if (ids.isEmpty) return;
    _syncing.addAll(ids);
    Trace.event('sync.mark', fields: {
      'added': ids.length,
      'held': _syncing.length,
    });
    notifyListeners();
  }

  void clearSyncing(String id) {
    if (_syncing.remove(id)) {
      Trace.event('sync.clear',
          fields: {'album': Trace.id(id), 'held': _syncing.length});
      notifyListeners();
    }
  }

  void clearAllSyncing() {
    if (_syncing.isEmpty) return;
    _syncing.clear();
    notifyListeners();
  }

  String? _userId;
  String? _email;
  String? _keepsyId;
  String _profileName = 'User';

  String? get userId => _userId;
  String? get email => _email;

  String? get keepsyId => _keepsyId;
  String get profileName => _profileName;

  void setUserData(Map<String, dynamic> data) {
    // The server response intentionally omits email, name and avatar plaintext
    _userId = data['id'];
    _keepsyId = data['keepsy_id'] as String?;

    notifyListeners();
    final id = _userId;
    if (id != null) _onUserKnown?.call(id);
  }

  // Seeds the account from the local cache so offline work can be bound to it
  void setCachedUserId(String id) {
    if (_userId != null) return;
    _userId = id;
    notifyListeners();
    _onUserKnown?.call(id);
  }

  void Function(String userId)? _onUserKnown;
  void attachUserKnown(void Function(String userId) hook) =>
      _onUserKnown = hook;

  void setEmail(String? email) {
    _email = email;
    notifyListeners();
  }

  void setProfileName(String name) {
    _profileName = name;
    // Persist locally so the profile screen still shows the right name on
    // next cold start. Per album name_ct publishing wires up in Phase 5
    unawaited(StorageService().saveName(name));
    notifyListeners();
  }

  // Called after a successful login to start receiving push events
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
    _summaryDebounce?.cancel();
    super.dispose();
  }
}
