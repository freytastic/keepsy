import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sodium/sodium_sumo.dart' show SodiumSumo, SodiumSumoInit;
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
import 'package:keepsy/domain/upload/upload_coordinator.dart';
import 'package:keepsy/ui/providers/upload_queue_model.dart';
import 'package:keepsy/data/api/realtime_service.dart';
import 'package:keepsy/data/storage/cache_root_key.dart';
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
import 'package:keepsy/secure_store/secure_key_store.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/shelf/seen_store_impl.dart';
import 'package:keepsy/ui/shelf/shelf_covers_impl.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/shelf/shelf_data.dart';
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
  // (auto-enabled by Flutter since the pkg ships as a plugin).
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

  // Compose the E2EE stack here so the rest of the app can 'context.read'
  // it via Provider. The platform SecureKeyStore factory throws on host : the
  // production app only runs this on iOS/Android, so the throw is the right
  // behavior. Tests inject their own SecureKeyStore + IdentityLabelMap
  final secureKeyStore = createSecureKeyStore();
  final labelMap = IdentityLabelMap();
  await labelMap.load();
  final prekeyApi = HttpPrekeyApi(ApiClientPrekeyJsonClient(apiClient));
  final identityService = IdentityService(
    store: secureKeyStore,
    labels: labelMap,
    api: prekeyApi,
  );

  // §4.2 client lane wiring: AlbumKeyStore (MK by epoch), MemberDirectory
  // (sender_token → ik/lk pubs via ListMembers), HttpEpochApi (current epoch
  // + per recipient wrap fetch), EpochProcessor (X3DH responder + AEAD +
  // installVerified). MemberDirectory's fetcher closure is the single point
  // where the e2ee/ layer touches lib/data/api/album_api.dart
  final albumKeyStore = AlbumKeyStore(secureKeyStore);
  // SecureKeyStore.initialize (wrapper key load) is cheap and is a hard
  // prerequisite for both the cache_root_key load below and
  // AlbumKeyStore.initialize (which calls _store.list)

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
  // Media cache : L1 RAM plaintext + L2 disk plaintext sealed under
  // cache_root_key. The cache key is pulled out of the keystore exactly once
  // here (the only per session AndroidKeyStore IPC for media) and held in RAM
  // for the process lifetime. L2 MUST be open before any album detail screen
  // renders since the cache manager awaits readBlob on the first widget build
  final mediaApi = MediaApi(apiClient);
  final cacheRootKey = await loadOrCreateCacheRootKey(secureKeyStore);
  // Persistent display name cache (sealed under cache_root_key). Reads are solely
  // CPU after this load, so titles/names paint without an album MK keystore hit
  final nameCache = await NameCache.open(cacheRootKey: cacheRootKey);
  // Attach the album title resolver now that the cache exists : cache hit ->
  // instant : miss -> one MK decrypt, then cached. Falls back to the
  // placeholder path (never caching a not yet decryptable sealed title)
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
  // Remove creator markers left by a crash after epoch 0 installed. The gate
  // already ignores them once local keys exist, but they need not persist.
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

  // member removal : orchestrates revoke→rotate (kick), revoke→wipe (leave),
  // and the pending rotation recovery. Pure logic lives in the coordinator, the
  // real API / rotator / cache closures are wired here. Album ids cross the port
  // boundary as raw 16-byte ids and are rendered to UUID strings for the data
  // layer inside each closure
  // Resolves the IK each remaining member's MK wrap must be bound to during a
  // removal rotation : my own token -> currentIkPub (we never pin "me"), every
  // other token -> its TOFU pin. A missing pin throws MissingIdentityPinException
  // and the rotation fails closed rather than wrap the new MK to a server
  // substituted bundle (finding #1, in the most sensitive flow)
  final expectedIkResolver = ExpectedIkResolver.responder(
    selfToken: (albumId) {
      final t = appState.selfMemberToken(_uuidStringFromBytes(albumId));
      return t == null ? null : base64.decode(base64.normalize(t));
    },
    // Roster identity : what a removal rotation wraps each remaining member's
    // MK to (call()). Every active member has one
    pinned: (albumId, token) =>
        identityPinStore.pinnedIk(hexAlbumId(albumId), base64.encode(token)),
    // Signing authority (check()/adopt()) : a strictly smaller set. Opening the
    // member list TOFU pins every unseen row, so reading the roster pin here
    // would let a server invented member grant itself the right to sign epochs
    // just by being displayed once
    signerPinned: (albumId, token) =>
        identityPinStore.signerIk(hexAlbumId(albumId), base64.encode(token)),
    currentIk: identityService.currentIkPub,
    // Only this device may sign until the album we just created installs its
    // epoch 0 : nobody else can have signed for an album that never had one
    soleSigner: (albumId) =>
        identityPinStore.isCreating(_uuidStringFromBytes(albumId)),
    // Responder side (check/adopt) addition : commits a first sight baseline
    // once the signature has proven the key, and is the only write the gate
    // makes. Moving an existing binding is markVerified's job
    pin: (albumId, token, ik) async {
      identityPinStore.pinSigner(hexAlbumId(albumId), base64.encode(token), ik);
      await identityPinStore.flush();
    },
  );
  // Verifies each epoch wrap against an IK bound locally to the sender's
  // member_token instead of the roster the server just handed us : without it
  // the server supplies both the wrap and the key that checks it
  final epochProcessor = EpochProcessor(
    api: epochApi,
    identity: identityService,
    store: albumKeyStore,
    directory: memberDirectory,
    signerGate: expectedIkResolver,
    invites: inviteApi, // backfill posts the join_complete receipt
  );
  // Key sync health : both dispatch paths below swallow throws, so these are
  // the only way a stalled album ever reaches the user
  epochProcessor.blocked.listen((b) {
    appState.setKeyBlock(_uuidStringFromBytes(b.albumId), b);
  });
  epochProcessor.unblocked.listen((e) {
    appState.clearKeyBlock(_uuidStringFromBytes(e.albumId), e.epoch);
  });
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
      // Drain cover work before clearing L2
      await shelfCovers.forget(albumStr);
      await mediaCacheManager.clearAlbum(albumStr);
      await seenStore.forget(albumStr);
      await albumKeyStore.deleteAlbumMKs(albumId);
      // Mark the album gone FIRST : this pops the open screen (setting
      // _accessLost) and makes in flight resolvers skip re caching, so the
      // durable name wipe below is the last write and stays wiped
      appState.removeAlbum(albumStr);
      await nameCache.clearAlbum(albumStr);
      // the roster is gone, so these pins can never be refreshed again
      await identityTrust.forgetAlbum(albumId);
    },
    isPendingRotation: (albumId) async {
      final cur = await epochApi.getCurrentEpoch(_uuidStringFromBytes(albumId));
      return cur?.pendingRotation ?? false;
    },
  );

  // Durable 403 fallback: if the live member_revoked WS event was
  // missed, the first album scoped request that comes back E_MEMBER_REVOKED
  // triggers the same local wipe. Idempotent with the WS path (the album may
  // already be gone)
  ApiClient.onMemberRevoked = (albumStr) {
    final albumId = _uuidStringToBytes(albumStr);
    if (albumId == null) return;
    memberRemoval.onSelfRemoved(albumId).catchError((_) {});
  };

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
    } else if (ev.type == 'e2ee.member_added') {
      final albumStr = ev.payload['album_id'] as String?;
      if (albumStr == null) return;
      appState.refreshSummarySoon();
      appState.notifyMemberChanged(albumStr);
    } else if (ev.type == 'e2ee.member_revoked') {
      // Either I was removed (wipe this album's local data) or another member
      // was (drop them from the directory so the roster re fetches). The server
      // emits member_revoked to the removed member specifically, so a self
      // wipe fires even though ive already left the active set
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
        memberRemoval.onSelfRemoved(albumId).catchError((_) {});
      } else {
        memberRemoval.onOtherRemoved(albumId, token);
        appState.refreshSummarySoon();
      }
      // Tell any open album screen its roster changed so the removed member
      // disappears live (self case pops the screen anyway; harmless there).
      appState.notifyMemberChanged(albumStr);
    }
  });

  // EpochProcessor signals a brand new album after _backfillJoin + receipt
  // succeed : refresh AppState.albums so the home grid shows the new tile
  // Fires post install so a fast tap never lands on a "syncing keys"
  // placeholder. Composes with both live joined:true events and the cold
  // start catchUpAll path (both go through _backfillJoin)
  epochProcessor.joinedAlbums.listen((albumIdBytes) async {
    final albumIdStr = _uuidStringFromBytes(albumIdBytes);
    await appState
        .refreshAlbumOnJoin(albumIdStr, albumService)
        .catchError((_) {});
    // Publish my global display name into the album me just joined (snapshot)
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

  // App scoped so uploads survive album navigation
  late final UploadQueueModel uploadQueue;
  final uploadCoordinator = UploadCoordinator(
    sources: PickedSourceStoreImpl(),
    preparer: MediaPreparerImpl(albumKeyStore),
    uploader: StagedMediaUploader(mediaApi),
    sink: UploadCacheSink(
      mediaCacheManager,
      (albumId) async {
        // Uploaders do not receive media_added events
        try {
          final fresh = await albumService.getMyAlbums();
          if (fresh != null) appState.setAlbums(fresh);
        } catch (_) {}
      },
      onPreview: (mediaId, thumb) => uploadQueue.putPreview(mediaId, thumb),
    ),
  );
  uploadQueue = UploadQueueModel(uploadCoordinator);
  // Resume paused albums only after key installation
  appState.attachUploadResume(uploadCoordinator.resumeAlbum);

  // Reconcile key state and catch up missed epochs after each reconnect.
  realtimeService.connected.listen((_) {
    unawaited(_onReconnect(identityService, epochProcessor, appState));
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
        Provider<DisplayNamePublisher>.value(value: displayNamePublisher),
        Provider<NameCache>.value(value: nameCache),
        Provider<IdentityTrust>.value(value: identityTrust),
        Provider<IdentityPinStore>.value(value: identityPinStore),
        Provider<InviteInitiator>.value(value: inviteInitiator),
        Provider<MediaCacheManager>.value(value: mediaCacheManager),
        Provider<MediaSealedCache>.value(value: mediaSealedCache),
        Provider<MediaCatalog>.value(value: mediaSealedCache),
        ListenableProvider<ShelfCovers>.value(value: shelfCovers),
        ListenableProvider<SeenStore>.value(value: seenStore),
        Provider<SodiumSumo>.value(value: sodium),
        Provider<MediaApi>.value(value: mediaApi),
        ChangeNotifierProvider<UploadQueueModel>.value(value: uploadQueue),
      ],
      child: KeepsyApp(
          mediaCacheManager: mediaCacheManager, shelfCovers: shelfCovers),
    ),
  );
}

// Settle SPK state before processing wraps, including for album-less accounts
Future<void> _onReconnect(
  IdentityService identity,
  EpochProcessor epochProcessor,
  AppState appState,
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
  } catch (_) {}
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

// Plain byte compare for "is this my member_token" : not a secrecy check, so a
// constant time compare isn't needed.
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
  const KeepsyApp({
    super.key,
    required this.mediaCacheManager,
    required this.shelfCovers,
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

  // Drop L1 (plaintext) on background or screen lock. L2 ciphertext stays on
  // disk : same security level as what S3 holds
  // inactive is excluded : image picker + transient interruptions fire
  // inactive then resume in ~1s , clearing L1 there nukes the thumb cache
  // every upload and forces L2→decrypt for everything visible on resume
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
      home: const LandingPage(),
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
