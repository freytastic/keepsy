import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sodium/sodium_sumo.dart' show SodiumSumo, SodiumSumoInit;
import 'package:keepsy/data/api/account_api.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/api/api_client.dart';
import 'package:keepsy/data/api/api_error.dart';
import 'package:keepsy/data/api/epoch_api.dart' as data_epoch;
import 'package:keepsy/data/api/error_mapper.dart';
import 'package:keepsy/data/api/invite_json_client.dart';
import 'package:keepsy/data/api/prekey_json_client.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/data/upload/upload_adapters.dart';
import 'package:keepsy/data/upload/upload_outbox.dart';
import 'package:keepsy/data/storage/storage_service.dart';
import 'package:keepsy/domain/account/account_deletion.dart';
import 'package:keepsy/domain/albums/album_cleanup.dart';
import 'package:keepsy/domain/upload/upload_coordinator.dart';
import 'package:keepsy/ui/providers/album_summary_refresher.dart';
import 'package:keepsy/ui/providers/upload_queue_model.dart';
import 'package:keepsy/data/api/realtime_service.dart';
import 'package:keepsy/data/storage/cache_root_key.dart';
import 'package:keepsy/data/storage/deletion_marker.dart';
import 'package:keepsy/data/storage/media_cache_manager.dart';
import 'package:keepsy/data/storage/media_plaintext_cache.dart';
import 'package:keepsy/data/storage/media_catalog.dart';
import 'package:keepsy/data/storage/media_sealed_cache.dart';
import 'package:keepsy/data/storage/identity_pin_store.dart';
import 'package:keepsy/data/models/album_summary.dart';
import 'package:keepsy/data/storage/name_cache.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/display_name.dart';
import 'package:keepsy/e2ee/sealed_name.dart';
import 'package:keepsy/e2ee/epoch_api.dart';
import 'package:keepsy/e2ee/epoch_processor.dart';
import 'package:keepsy/e2ee/epoch_rotator.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/e2ee/expected_ik_resolver.dart';
import 'package:keepsy/e2ee/identity_trust.dart';
import 'package:keepsy/e2ee/identity_label_map.dart';
import 'package:keepsy/e2ee/invite.dart';
import 'package:keepsy/e2ee/invite_api.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/e2ee/member_directory.dart';
import 'package:keepsy/e2ee/member_removal.dart';
import 'package:keepsy/e2ee/prekey_api.dart';
import 'package:keepsy/e2ee/rotation_recovery.dart';
import 'package:keepsy/secure_store/key_store_exceptions.dart';
import 'package:keepsy/secure_store/secure_key_store.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/shelf/seen_store_impl.dart';
import 'package:keepsy/ui/shelf/shelf_covers_impl.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/shelf/shelf_data.dart';
import 'package:keepsy/ui/screens/account_deletion_screen.dart';
import 'package:keepsy/ui/screens/landing_screen.dart';
import 'package:keepsy/ui/screens/onboarding_screen.dart';

// Lets the global error handler navigate and show messages
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Native libsodium for X25519/Ed25519 (sumo variant exposes raw
  // crypto_scalarmult). AES-GCM/ChaCha20 stay on cryptography_flutter
  // auto-enabled by Flutter since the package ships as a plugin
  final sodium = await SodiumSumoInit.init();
  Sign.bindSodium(sodium);
  Kex.bindSodium(sodium);

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    final err = details.exception;
    if (err is ApiError) {
      _showApiError(err);
    }
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    if (error is ApiError) {
      _showApiError(error);
      return true;
    }
    return false;
  };

  final appState = AppState();
  final apiClient = ApiClient();
  final realtimeService = RealtimeService(apiClient);

  // Tests inject host-safe key stores while production uses the platform store
  final secureKeyStore = createSecureKeyStore();
  final labelMap = IdentityLabelMap();
  await labelMap.load();
  final prekeyApi = HttpPrekeyApi(ApiClientPrekeyJsonClient(apiClient));
  final identityService = IdentityService(
    store: secureKeyStore,
    labels: labelMap,
    api: prekeyApi,
  );

  // MemberDirectory is the E2EE layer's only route to album membership data
  final albumKeyStore = AlbumKeyStore(secureKeyStore);
  // Wrapper-key initialization must precede every key-backed store

  await secureKeyStore.initialize();
  unawaited(_prewarmAlbumKeyStore(albumKeyStore));
  final albumService = AlbumService();
  final displayNamePublisher = DisplayNamePublisher(
    ks: albumKeyStore,
    putProfileCt: (albumId, ct) => albumService.putProfileCt(albumId, ct),
  );
  // The album title resolver is attached after cache_root_key/NameCache load
  // (below), since it reads through the persistent name cache
  final memberDirectory = MemberDirectory((albumId) async {
    final members =
        await albumService.listMembers(_uuidStringFromBytes(albumId));
    final out = <MemberRecord>[];
    for (final m in members) {
      if (m.revoked) continue;
      final ik = m.profile.ikPub;
      final lk = m.profile.lkPub;
      if (ik == null || lk == null) continue;
      out.add(MemberRecord(
        memberToken: base64Decode(m.memberToken),
        ikPub: base64Decode(ik),
        lkPub: base64Decode(lk),
      ));
    }
    return out;
  });
  final epochApi = HttpEpochApi(data_epoch.ApiClientEpochJsonClient(apiClient));
  final inviteApi = HttpInviteApi(ApiClientInviteJsonClient(apiClient));
  // Initiates epoch 0 during album creation and rotations after member removal
  final epochRotator = EpochRotator(
    epochs: epochApi,
    prekeys: prekeyApi,
    identity: identityService,
    aks: albumKeyStore,
    // member removal rotates for members known only by token (identity
    // hidden) : HttpPrekeyApi doubles as the by token bundle fetcher
    memberBundles: prekeyApi,
  );
  // Load the media cache key once and open L2 before album screens can render
  final mediaApi = MediaApi(apiClient);
  final cacheRootKey = await loadOrCreateCacheRootKey(secureKeyStore);
  final nameCache = await NameCache.open(cacheRootKey: cacheRootKey);
  // Cache only titles that decrypt successfully under an installed MK
  appState.attachAlbumNameResolver((albumId, nameCt) async {
    if (nameCt == null || nameCt.isEmpty) return 'Untitled Album';
    final key = NameCache.albumKey(albumId);
    final cached = nameCache.get(key, nameCt);
    if (cached != null) return cached;
    final b = _uuidStringToBytes(albumId);
    if (b == null) return 'Untitled Album';
    final opened = await SealedName.openAlbumName(albumKeyStore, b, nameCt);
    if (opened != null) {
      // Dont cache a title for an album we've since left/removed (an in flight
      // resolve can finish after the wipe)
      if (appState.albums.any((a) => a.id == albumId)) {
        nameCache.put(key, opened, nameCt);
      }
      return opened;
    }
    return resolveAlbumName(albumKeyStore, b, nameCt);
  });
  appState.attachMemberNameResolver((albumId, memberToken, nameCt) async {
    if (nameCt == null || nameCt.isEmpty) return null;
    final key = NameCache.memberKey(albumId, memberToken);
    final cached = nameCache.get(key, nameCt);
    if (cached != null) return cached;
    final b = _uuidStringToBytes(albumId);
    if (b == null) return null;
    final token = base64.decode(base64.normalize(memberToken));
    final opened =
        await SealedName.openMemberName(albumKeyStore, b, token, nameCt);
    if (opened != null && appState.albums.any((a) => a.id == albumId)) {
      nameCache.put(key, opened, nameCt);
    }
    return opened;
  });
  // Roster pins, verification claims, signer bindings, and creator markers are
  // sealed under cache_root_key and survive normal logout
  final identityPinStore =
      await IdentityPinStore.open(cacheRootKey: cacheRootKey);
  // Remove creator markers left by a crash after epoch 0 installed
  for (final albumIdStr in identityPinStore.creatingAlbums) {
    final b = _uuidStringToBytes(albumIdStr);
    if (b == null || await albumKeyStore.latestEpoch(b) >= 0) {
      await identityPinStore.clearCreating(albumIdStr);
    }
  }
  final identityTrust =
      IdentityTrust(identity: identityService, pins: identityPinStore);
  // look up an invitee by keepsy_id + ship all historical MKs. The pinner
  // anchors first contact TOFU on the IK we wrap to (finding #1, invite path)
  final inviteInitiator = InviteInitiator(
    prekeys: prekeyApi,
    invites: inviteApi,
    identity: identityService,
    aks: albumKeyStore,
    pinner: InviteIdentityPinner(
      pinnedIk: (albumId, token) =>
          identityPinStore.pinnedIk(hexAlbumId(albumId), base64.encode(token)),
      pin: (albumId, token, ik) async {
        identityPinStore.pin(hexAlbumId(albumId), base64.encode(token), ik);
        await identityPinStore.flush();
      },
    ),
  );
  final mediaSealedCache =
      await MediaSealedCache.open(cacheRootKey: cacheRootKey);
  final uploadOutbox = await UploadOutboxStore.open(cacheRootKey: cacheRootKey);
  final deletionMarker = await DeletionMarkerFile.open();
  PendingDeletion? pendingDeletion;
  try {
    pendingDeletion = await deletionMarker.read();
  } catch (_) {}
  // Seed the shelf before the first network request
  try {
    final localAlbums = await mediaSealedCache.loadAlbums();
    if (localAlbums.isNotEmpty) appState.setAlbums(localAlbums);
  } catch (_) {}

  // Persist every AppState shelf mutation
  appState.attachShelfPersistence(mediaSealedCache.saveAlbums);
  final mediaPlaintextCache = MediaPlaintextCache();
  // Seen state must survive media cache eviction
  final seenStore = await SealedSeenStore.open(cacheRootKey: cacheRootKey);
  final shelfCovers = ShelfCoversImpl(
    sealedCache: mediaSealedCache,
    api: mediaApi,
    albumKeys: albumKeyStore,
  );
  // Unknown albums start at their current generation
  void seedWatermarks() {
    for (final a in appState.albums) {
      // Do not seed from an unknown generation
      if (!a.hasSummary) continue;
      if (!seenStore.knows(a.id)) {
        unawaited(seenStore.markSeen(a.id, a.mediaGeneration));
      }
    }
  }

  appState.addListener(seedWatermarks);
  seedWatermarks();

  // Reconcile gaps in realtime summary data
  appState.attachSummaryRefresh(() async {
    final fresh = await albumService.getMyAlbums();
    if (fresh != null) appState.setAlbums(fresh);
  });

  final mediaCacheManager = MediaCacheManager(
    plaintext: mediaPlaintextCache,
    ciphertext: mediaSealedCache,
    api: mediaApi,
    aks: albumKeyStore,
  );

  // Removal rotations bind every new wrap to a locally trusted identity key
  // A missing pin fails before the new MK is generated
  final expectedIkResolver = ExpectedIkResolver.responder(
    selfToken: (albumId) {
      final t = appState.selfMemberToken(_uuidStringFromBytes(albumId));
      return t == null ? null : base64.decode(base64.normalize(t));
    },
    // Every remaining member needs a roster identity pin
    pinned: (albumId, token) =>
        identityPinStore.pinnedIk(hexAlbumId(albumId), base64.encode(token)),
    // Roster discovery must never grant epoch-signing authority
    signerPinned: (albumId, token) =>
        identityPinStore.signerIk(hexAlbumId(albumId), base64.encode(token)),
    currentIk: identityService.currentIkPub,
    // Only the creator may sign before epoch 0 installs
    soleSigner: (albumId) =>
        identityPinStore.isCreating(_uuidStringFromBytes(albumId)),
    // First sight is pinned only after its signature proves the key
    pin: (albumId, token, ik) async {
      identityPinStore.pinSigner(hexAlbumId(albumId), base64.encode(token), ik);
      await identityPinStore.flush();
    },
  );
  // Verify wraps against locally bound signer keys, never server-supplied keys
  final epochProcessor = EpochProcessor(
    api: epochApi,
    identity: identityService,
    store: albumKeyStore,
    directory: memberDirectory,
    signerGate: expectedIkResolver,
    invites: inviteApi, // backfill posts the join_complete receipt
  );
  // Surface failures swallowed by background epoch dispatch
  epochProcessor.blocked.listen((b) {
    appState.setKeyBlock(_uuidStringFromBytes(b.albumId), b);
  });
  late final RotationRecoveryScheduler rotationRecovery;
  late final UploadQueueModel uploadQueue;
  epochProcessor.unblocked.listen((e) {
    appState.clearKeyBlock(_uuidStringFromBytes(e.albumId), e.epoch);
    rotationRecovery.onEpochInstalled(e.albumId);
  });
  Future<bool> isRotationRequired(Uint8List albumId) async {
    final cur = await epochApi.getCurrentEpoch(_uuidStringFromBytes(albumId));
    return cur?.rotationRequired ?? false;
  }

  // Installing the authoritative epoch is what releases an album's queued
  // photos : the realtime echo that normally does it is only a hint
  Future<void> reconcileAlbumKeys(Uint8List albumId) async {
    final cur = await epochApi.getCurrentEpoch(_uuidStringFromBytes(albumId));
    if (cur == null) return;
    await epochProcessor.handleEvent(albumId: albumId, epoch: cur.currentEpoch);
  }

  final memberRemoval = MemberRemovalCoordinator(
    revoke: (albumId, token) => albumService.removeMember(
        _uuidStringFromBytes(albumId), base64.encode(token)),
    activeTokens: (albumId) async {
      final members =
          await albumService.listMembers(_uuidStringFromBytes(albumId));
      return [
        for (final m in members)
          if (!m.revoked) base64.decode(base64.normalize(m.memberToken)),
      ];
    },
    currentEpoch: (albumId) => albumKeyStore.latestEpoch(albumId),
    rotate: (albumId, epoch, recipients) => epochRotator.rotate(
        albumIdBytes: albumId, epoch: epoch, recipients: recipients),
    expectedIk: expectedIkResolver.call,
    dropDirectory: (albumId, token) => memberDirectory.drop(albumId, token),
    wipeLocalAlbum: (albumId) async {
      final albumStr = _uuidStringFromBytes(albumId);
      // Queued photos and their sealed keys must not outlive the album
      final picks = await uploadQueue.forgetAlbum(albumStr);
      await shelfCovers.forget(albumStr);
      await mediaCacheManager.clearAlbum(albumStr);
      await seenStore.forget(albumStr);
      await albumKeyStore.deleteAlbumMKs(albumId);
      // Mark gone first so in-flight resolvers cannot repopulate wiped data
      appState.removeAlbum(albumStr);
      await mediaSealedCache.dropAlbum(albumStr);
      await nameCache.clearAlbum(albumStr);
      await identityTrust.forgetAlbum(albumId);
      rotationRecovery.forget(albumId);
      // Several of the steps above swallow delete failures by design, so the
      // cleanup record is only released once nothing is found
      final left = <String>[
        for (final path in picks)
          if (await File(path).exists()) 'picked photo',
        if (uploadQueue.holdsAlbum(albumStr)) 'upload queue',
        if (await uploadOutbox.holdsAlbum(albumStr)) 'sealed uploads',
        if ((await mediaSealedCache.listRecordsForAlbum(albumStr)).isNotEmpty)
          'media catalog',
        if ((await mediaSealedCache.coversFor(albumStr)).isNotEmpty) 'covers',
        if ((await mediaSealedCache.loadAlbums()).any((a) => a.id == albumStr))
          'shelf',
        if (await albumKeyStore.latestEpoch(albumId) >= 0) 'album keys',
        if (nameCache.holdsAlbum(albumStr)) 'names',
        if (identityPinStore.holdsAlbum(hexAlbumId(albumId))) 'pins',
        if (seenStore.holdsAlbum(albumStr)) 'seen state',
      ];
      if (left.isNotEmpty) {
        throw StateError('album data left behind: ${left.join(', ')}');
      }
    },
    isRotationRequired: isRotationRequired,
  );
  // Persists every album loss until its local wipe is verified
  final albumCleanup = AlbumCleanupQueue(
    store: mediaSealedCache,
    probe: albumService.probeAlbum,
    wipe: (albumStr) async {
      final albumId = _uuidStringToBytes(albumStr);
      if (albumId != null) await memberRemoval.onSelfRemoved(albumId);
    },
  );
  rotationRecovery = RotationRecoveryScheduler(
    isRotationRequired: isRotationRequired,
    canRotate: (albumId) => appState.isAdminOf(_uuidStringFromBytes(albumId)),
    recover: memberRemoval.recoverIfPending,
    reconcile: reconcileAlbumKeys,
  );
  rotationRecovery.status.listen((s) {
    appState.setRotationStatus(_uuidStringFromBytes(s.albumId), s);
  });
  appState.attachRotationPrompt((albumId) {
    final b = _uuidStringToBytes(albumId);
    if (b != null) unawaited(rotationRecovery.request(b));
  });

  // Membership errors trigger durable cleanup when realtime events were missed
  ApiClient.onMemberRevoked = (albumStr) {
    unawaited(albumCleanup.albumGone(albumStr).catchError((_) {}));
  };
  void onAlbumDeleted(String albumStr) {
    appState.markAlbumDeleted(albumStr);
    unawaited(albumCleanup.albumGone(albumStr).catchError((_) {}));
  }

  ApiClient.onNotMember = onAlbumDeleted;
  // A listing can race a just created album, so an omission is probed first
  appState.attachAlbumsVanished((ids) {
    for (final id in ids) {
      unawaited(albumCleanup.albumMissing(id).catchError((_) {}));
    }
  });
  unawaited(albumCleanup.drain());

  // WS dispatcher. Epoch failures are surfaced through EpochProcessor.blocked
  // and swallowed here so one bad event cannot terminate the listener
  realtimeService.stream.listen((ev) {
    if (ev.type == 'e2ee.opk_low') {
      identityService.replenishOpks();
    } else if (ev.type == 'e2ee.epoch_changed') {
      final albumStr = ev.payload['album_id'] as String?;
      final epoch = ev.payload['epoch'];
      final joined = ev.payload['joined'] == true;
      if (albumStr == null || epoch is! int) return;
      final albumId = _uuidStringToBytes(albumStr);
      if (albumId == null) return;
      epochProcessor
          .handleEvent(albumId: albumId, epoch: epoch, joined: joined)
          .catchError((_) {});
    } else if (ev.type == 'e2ee.media_added') {
      final albumStr = ev.payload['album_id'] as String?;
      final mediaStr = ev.payload['media_id'] as String?;
      if (albumStr == null || mediaStr == null) return;
      final recJson = ev.payload['record'];
      if (recJson is Map<String, dynamic>) {
        try {
          final r = MediaRecord.fromJson(recJson);
          unawaited(mediaCacheManager.acceptNewMedia(r));
        } catch (_) {
          unawaited(mediaCacheManager.prefetch(albumStr, mediaStr));
        }
      } else {
        unawaited(mediaCacheManager.prefetch(albumStr, mediaStr));
      }
      final gen = ev.payload['media_generation'];
      if (gen is int) {
        appState.applyMediaAdded(albumStr, gen,
            preview: recJson is Map<String, dynamic>
                ? PreviewMedia.tryFromRecordJson(recJson)
                : null);
      }
      appState.notifyMediaAdded(albumStr, mediaStr);
    } else if (ev.type == 'e2ee.album_deleted') {
      final albumStr = ev.payload['album_id'] as String?;
      if (albumStr != null) onAlbumDeleted(albumStr);
    } else if (ev.type == 'e2ee.media_deleted') {
      final albumStr = ev.payload['album_id'] as String?;
      final ids = ev.payload['media_ids'];
      if (albumStr == null || ids is! List) return;
      unawaited(() async {
        for (final id in ids.whereType<String>()) {
          await mediaCacheManager.invalidate(id);
        }
        appState.notifyMediaRemoved(albumStr);
      }());
    } else if (ev.type == 'e2ee.member_added') {
      final albumStr = ev.payload['album_id'] as String?;
      if (albumStr == null) return;
      appState.refreshSummarySoon();
      appState.notifyMemberChanged(albumStr);
    } else if (ev.type == 'e2ee.member_revoked') {
      // Self removal wipes the album while another removal refreshes its roster
      final albumStr = ev.payload['album_id'] as String?;
      final tokenB64 = ev.payload['member_token'] as String?;
      if (albumStr == null || tokenB64 == null) return;
      final albumId = _uuidStringToBytes(albumStr);
      if (albumId == null) return;
      final token = base64.decode(base64.normalize(tokenB64));
      String? myTokenB64;
      for (final a in appState.albums) {
        if (a.id == albumStr) {
          myTokenB64 = a.memberToken;
          break;
        }
      }
      final isSelf = myTokenB64 != null &&
          _bytesEqual(base64.decode(base64.normalize(myTokenB64)), token);
      if (isSelf) {
        unawaited(albumCleanup.albumGone(albumStr).catchError((_) {}));
      } else {
        memberRemoval.onOtherRemoved(albumId, token);
        appState.refreshSummarySoon();
        unawaited(rotationRecovery.request(albumId));
      }
      appState.notifyMemberChanged(albumStr);
    }
  });

  // Joined albums appear only after their keys install
  epochProcessor.joinedAlbums.listen((albumIdBytes) async {
    final albumIdStr = _uuidStringFromBytes(albumIdBytes);
    await appState
        .refreshAlbumOnJoin(albumIdStr, albumService)
        .catchError((_) {});
    final name = appState.profileName;
    if (name.isEmpty) return;
    String? tok;
    for (final a in appState.albums) {
      if (a.id == albumIdStr) {
        tok = a.memberToken;
        break;
      }
    }
    if (tok == null) return;
    try {
      final tokenBytes = base64Decode(tok);
      await displayNamePublisher.publishToAlbum(
          albumId: albumIdStr, memberToken: tokenBytes, name: name);
    } catch (_) {}
  });

  final summaryRefresher = AlbumSummaryRefresher(
    fetch: albumService.getMyAlbums,
    apply: appState.setAlbums,
  );
  final pickedSources = PickedSourceStoreImpl();
  final mediaPreparer = MediaPreparerImpl(albumKeyStore, uploadOutbox,
      owner: () => appState.userId);
  final uploadCoordinator = UploadCoordinator(
    sources: pickedSources,
    onRotationPending: (albumId) {
      final b = _uuidStringToBytes(albumId);
      if (b != null) unawaited(rotationRecovery.request(b));
    },
    preparer: mediaPreparer,
    uploader: StagedMediaUploader(mediaApi),
    sink: UploadCacheSink(
      mediaCacheManager,
      (albumId) => summaryRefresher.refresh(),
      onPreview: (mediaId, thumb) => uploadQueue.putPreview(mediaId, thumb),
      selfToken: appState.selfMemberToken,
    ),
  );
  uploadQueue = UploadQueueModel(uploadCoordinator);
  // Sealed photos are bound to an account, so restore waits until it is known
  appState.attachUserKnown((userId) {
    unawaited(StorageService().saveUserId(userId));
    unawaited(uploadQueue.restore());
  });
  unawaited(pickedSources.sweepStaleStaging());
  appState.attachUploadResume(uploadCoordinator.resumeAlbum);

  // Stop work that can reach the server or write plaintext before clearing stores
  // Every step is idempotent because a failed wipe repeats them
  var catalogClosed = false;
  final terminalWipe = TerminalWipe(
    steps: [
      (name: 'network', run: () async => ApiClient.terminate()),
      (name: 'realtime', run: realtimeService.terminate),
      (name: 'uploads', run: uploadQueue.shutdown),
      (name: 'prepared photo', run: () async => mediaPreparer.wipeMemory()),
      (name: 'album cleanup', run: albumCleanup.shutdown),
      (name: 'covers', run: shelfCovers.shutdown),
      (name: 'downloads', run: mediaCacheManager.shutdown),
      (name: 'auth', run: StorageService().deleteAuth),
      (name: 'session', run: () async => appState.reset()),
      (
        name: 'catalog',
        run: () async {
          if (catalogClosed) return;
          await mediaCacheManager.clearAll();
          await mediaSealedCache.saveAlbums(const []);
          await mediaSealedCache.close();
          catalogClosed = true;
        }
      ),
      (name: 'outbox', run: uploadOutbox.clearAll),
      (name: 'names', run: nameCache.clear),
      (name: 'pins', run: identityPinStore.clear),
      (name: 'seen', run: seenStore.clear),
      // Closed before the keystore goes so no late install recreates it
      (name: 'key handles', run: () async => albumKeyStore.forgetAll()),
      (name: 'labels', run: labelMap.clearAll),
      (name: 'keystore', run: secureKeyStore.wipeAll),
      (
        name: 'secure storage',
        run: () => const FlutterSecureStorage().deleteAll()
      ),
      (
        name: 'preferences',
        run: () async => (await SharedPreferences.getInstance()).clear()
      ),
      // Catch alls for picker copies, temp files and anything a store missed
      (
        name: 'support dir',
        run: () async => _emptyDir(await getApplicationSupportDirectory())
      ),
      (
        name: 'cache dir',
        run: () async => _emptyDir(await getApplicationCacheDirectory())
      ),
      (
        name: 'temp dir',
        run: () async => _emptyDir(await getTemporaryDirectory())
      ),
      (
        name: 'cache key',
        run: () async => cacheRootKey.fillRange(0, cacheRootKey.length, 0)
      ),
    ],
    leftovers: () => _wipeLeftovers(secureKeyStore),
  );
  final accountDeletion = AccountDeletion(
    api: HttpAccountDeletionApi(apiClient),
    marker: deletionMarker,
    wipe: terminalWipe.run,
    random: Csprng.bytes,
  );

  // Reconcile key state and catch up missed epochs after each reconnect
  realtimeService.connected.listen((_) {
    unawaited(albumCleanup.drain());
    unawaited(_onReconnect(
        identityService, epochProcessor, appState, rotationRecovery));
  });

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appState),
        Provider.value(value: realtimeService),
        Provider<IdentityLabelMap>.value(value: labelMap),
        Provider<IdentityService>.value(value: identityService),
        Provider<AlbumKeyStore>.value(value: albumKeyStore),
        Provider<MemberDirectory>.value(value: memberDirectory),
        Provider<EpochProcessor>.value(value: epochProcessor),
        Provider<EpochRotator>.value(value: epochRotator),
        Provider<MemberRemovalCoordinator>.value(value: memberRemoval),
        Provider<RotationRecoveryScheduler>.value(value: rotationRecovery),
        Provider<DisplayNamePublisher>.value(value: displayNamePublisher),
        Provider<NameCache>.value(value: nameCache),
        Provider<IdentityTrust>.value(value: identityTrust),
        Provider<IdentityPinStore>.value(value: identityPinStore),
        Provider<InviteInitiator>.value(value: inviteInitiator),
        Provider<MediaCacheManager>.value(value: mediaCacheManager),
        Provider<MediaSealedCache>.value(value: mediaSealedCache),
        Provider<MediaCatalog>.value(value: mediaSealedCache),
        Provider<AlbumCatalog>.value(value: mediaSealedCache),
        ListenableProvider<ShelfCovers>.value(value: shelfCovers),
        ListenableProvider<SeenStore>.value(value: seenStore),
        Provider<SodiumSumo>.value(value: sodium),
        Provider<MediaApi>.value(value: mediaApi),
        ChangeNotifierProvider<UploadQueueModel>.value(value: uploadQueue),
        Provider<AccountDeletion>.value(value: accountDeletion),
      ],
      child: KeepsyApp(
        mediaCacheManager: mediaCacheManager,
        shelfCovers: shelfCovers,
        resumeDeletion: pendingDeletion == null ? null : accountDeletion,
      ),
    ),
  );
}

// Settle SPK state before processing wraps, including for album-less accounts
Future<void> _onReconnect(
  IdentityService identity,
  EpochProcessor epochProcessor,
  AppState appState,
  RotationRecoveryScheduler rotationRecovery,
) async {
  try {
    await identity.settleSpkState();
  } catch (_) {/*diagnostics are logged inside */}

  final ids = <Uint8List>[];
  for (final a in appState.albums) {
    final b = _uuidStringToBytes(a.id);
    if (b != null) ids.add(b);
  }
  if (ids.isEmpty) return;
  try {
    // Per album resilient + idempotent : overlapping with landing_screen's
    // cold start call is harmless, so both entry points keep their own
    await epochProcessor.catchUpAll(ids);
    // Newly installed MKs may make album titles decryptable now
    appState.refreshAlbumNames();
    await rotationRecovery.checkAll(ids);
  } catch (_) {}
}

// Everything goes except the deletion marker, which is cleared only once the
// wipe has been verified
bool _survivesWipe(String name) =>
    name == kDeletionMarkerName || name.startsWith('com.apple.');

Future<void> _emptyDir(Directory dir) async {
  if (!await dir.exists()) return;
  final failed = <String>[];
  await for (final entry in dir.list(followLinks: false)) {
    final name = p.basename(entry.path);
    if (_survivesWipe(name)) continue;
    try {
      await entry.delete(recursive: true);
    } catch (_) {
      failed.add(name);
    }
  }
  if (failed.isNotEmpty) {
    throw FileSystemException('not deleted', failed.join(', '));
  }
}

// Checked after the steps instead of trusting them, since several stores
// swallow their own delete failures by design
Future<List<String>> _wipeLeftovers(SecureKeyStore keys) async {
  final left = <String>[];
  for (final dir in [
    await getApplicationSupportDirectory(),
    await getApplicationCacheDirectory(),
    await getTemporaryDirectory(),
  ]) {
    if (!await dir.exists()) continue;
    await for (final entry in dir.list(followLinks: false)) {
      final name = p.basename(entry.path);
      if (!_survivesWipe(name)) left.add('file $name');
    }
  }
  if ((await const FlutterSecureStorage().readAll()).isNotEmpty) {
    left.add('secure storage');
  }
  if ((await SharedPreferences.getInstance()).getKeys().isNotEmpty) {
    left.add('preferences');
  }
  try {
    if ((await keys.list()).isNotEmpty) left.add('keystore');
  } on KeyStoreUninitializedException {
    // The wrapper key is gone, which is what a wiped store looks like
  }
  return left;
}

Future<void> _prewarmAlbumKeyStore(AlbumKeyStore aks) async {
  try {
    await aks.initialize();
  } catch (_) {}
}

// Canonical 8-4-4-4-12 hex form for raw 16B UUIDs. Inline here so main.dart
// doesnt pull package:uuid for one tiny conversion
String _uuidStringFromBytes(Uint8List b) {
  if (b.length != 16) {
    throw ArgumentError('albumId must be 16 bytes, got ${b.length}');
  }
  final s = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
      '-${s.substring(16, 20)}-${s.substring(20)}';
}

Uint8List? _uuidStringToBytes(String s) {
  final hex = s.replaceAll('-', '');
  if (hex.length != 32) return null;
  final out = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    final v = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (v == null) return null;
    out[i] = v;
  }
  return out;
}

// Member tokens are compared here only for routing, not as secrets
bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void _showApiError(ApiError err) {
  final ux = mapApiError(err);
  rootMessengerKey.currentState?.showSnackBar(
    SnackBar(
      content: Text(ux.userMessage),
      duration: ux.isTransient
          ? const Duration(seconds: 3)
          : const Duration(seconds: 6),
      behavior: SnackBarBehavior.floating,
    ),
  );
  if (ux.action == ErrorRecovery.abortAndReauth) {
    rootNavigatorKey.currentState?.pushNamedAndRemoveUntil(
      '/login',
      (_) => false,
    );
  }
}

class KeepsyApp extends StatefulWidget {
  final MediaCacheManager mediaCacheManager;
  final ShelfCoversImpl shelfCovers;
  // Set when an earlier run confirmed a deletion it never saw finish
  final AccountDeletion? resumeDeletion;
  const KeepsyApp({
    super.key,
    required this.mediaCacheManager,
    required this.shelfCovers,
    this.resumeDeletion,
  });

  @override
  State<KeepsyApp> createState() => _KeepsyAppState();
}

class _KeepsyAppState extends State<KeepsyApp> with WidgetsBindingObserver {
  // Hides shelf photos from task switcher snapshots
  bool _shielded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Clear plaintext on background but ignore transient inactive states
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Task switcher snapshots precede pause
    final shield = state != AppLifecycleState.resumed;
    if (shield != _shielded) setState(() => _shielded = shield);

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      widget.mediaCacheManager.onAppPaused();
      widget.shelfCovers.suspend();
    } else if (state == AppLifecycleState.resumed) {
      widget.shelfCovers.resume();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Keepsy',
      debugShowCheckedModeBanner: false,
      navigatorKey: rootNavigatorKey,
      scaffoldMessengerKey: rootMessengerKey,
      theme: Warm.theme,
      home: widget.resumeDeletion == null
          ? const LandingPage()
          : AccountDeletionScreen(
              deletion: widget.resumeDeletion!,
              onNotAccepted: (_) => const LandingPage(),
            ),
      routes: {
        '/login': (_) => const OnboardingScreen(),
      },
      builder: (context, child) => Stack(
        children: [
          if (child != null) child,
          if (_shielded)
            const Positioned.fill(
              child: ColoredBox(color: Warm.ground),
            ),
        ],
      ),
    );
  }
}
