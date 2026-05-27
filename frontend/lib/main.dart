import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

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
import 'package:keepsy/data/api/realtime_service.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/epoch_api.dart';
import 'package:keepsy/e2ee/epoch_processor.dart';
import 'package:keepsy/e2ee/epoch_rotator.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/e2ee/identity_label_map.dart';
import 'package:keepsy/e2ee/invite.dart';
import 'package:keepsy/e2ee/invite_api.dart';
import 'package:keepsy/e2ee/member_directory.dart';
import 'package:keepsy/e2ee/prekey_api.dart';
import 'package:keepsy/secure_store/secure_key_store.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/screens/landing_screen.dart';
import 'package:keepsy/ui/screens/login_screen.dart';
import 'package:keepsy/ui/theme/app_theme.dart';

// Top-level so the global error boundary in this file can resolve a
// messenger and route. Lives in ui/ — the data layer must not see it.
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
  // Warm SecureKeyStore (wrapper key creation) + AlbumKeyStore (_store.list
  // for _rebuildPresence) during login/landing idle
  // cold first album installVerified ~700ms for the
  // _store.list() inside _rebuildPresence, this folds that cost into the
  // network bound login flow instead of the album create blocking path
  // Must call SecureKeyStore.initialize first : AlbumKeyStore.initialize calls
  // _store.list which throws KeyStoreUninitializedException without it
  unawaited(_prewarmKeyStores(secureKeyStore, albumKeyStore));
  final albumService = AlbumService();
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
  final epochProcessor = EpochProcessor(
    api: epochApi,
    identity: identityService,
    store: albumKeyStore,
    directory: memberDirectory,
    invites: inviteApi, // §6.3 : backfill posts the join_complete receipt
  );
  // EpochRotator : initiator side of an epoch transition. Used rn for the
  // §5 bootstrap (epoch 0 on album create) : §6 invites + §7 removals will
  // reuse the same machinery
  final epochRotator = EpochRotator(
    epochs: epochApi,
    prekeys: prekeyApi,
    identity: identityService,
    aks: albumKeyStore,
  );
  // look up an invitee by keepsy_id + ship all historical MKs
  final inviteInitiator = InviteInitiator(
    prekeys: prekeyApi,
    invites: inviteApi,
    identity: identityService,
    aks: albumKeyStore,
  );

  // WS dispatcher: e2ee.opk_low → replenishOpks (service level mutex
  // collapses bursts), e2ee.epoch_changed → EpochProcessor.handleEvent
  // (per album mutex serialises events). OpkNotFoundException + verification
  // failures are logged + swallowed at the dispatch boundary so the listener
  // chain doesnt die on a single bad event
  realtimeService.stream.listen((ev) {
    if (ev.type == 'e2ee.opk_low') {
      identityService.replenishOpks();
    } else if (ev.type == 'e2ee.epoch_changed') {
      final albumStr = ev.payload['album_id'] as String?;
      final epoch = ev.payload['epoch'];
      if (albumStr == null || epoch is! int) return;
      final albumId = _uuidStringToBytes(albumStr);
      if (albumId == null) return;
      epochProcessor
          .handleEvent(albumId: albumId, epoch: epoch)
          .catchError((Object e, StackTrace s) {
        developer.log('epoch_changed handler failed',
            name: 'keepsy.e2ee', error: e, stackTrace: s);
      });
    }
  });

  // WS reconnect catch up : every successful WS open replays the cold start
  // catchUpAll so any e2ee.epoch_changed events that fired while the socket
  // was down get resolved. catchUpAll is per album resilient + idempotent so
  // overlap with landing_screen's call is harmless
  realtimeService.connected.listen((_) {
    final ids = <Uint8List>[];
    for (final a in appState.albums) {
      final b = _uuidStringToBytes(a.id);
      if (b != null) ids.add(b);
    }
    if (ids.isEmpty) return;
    epochProcessor.catchUpAll(ids).catchError((Object e, StackTrace s) {
      developer.log('reconnect catchUpAll failed',
          name: 'keepsy.e2ee', error: e, stackTrace: s);
    });
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
        Provider<InviteInitiator>.value(value: inviteInitiator),
        Provider<SodiumSumo>.value(value: sodium),
      ],
      child: const KeepsyApp(),
    ),
  );
}

Future<void> _prewarmKeyStores(SecureKeyStore store, AlbumKeyStore aks) async {
  try {
    await store.initialize();
    await aks.initialize();
  } catch (e, s) {
    developer.log('keystore prewarm failed (non-fatal)',
        name: 'keepsy.startup', error: e, stackTrace: s);
  }
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

class KeepsyApp extends StatelessWidget {
  const KeepsyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = context.select((AppState s) => s.isDark);
    final accent = context.select((AppState s) => s.accent);

    return MaterialApp(
      title: 'Keepsy',
      debugShowCheckedModeBanner: false,
      navigatorKey: rootNavigatorKey,
      scaffoldMessengerKey: rootMessengerKey,
      theme: K.theme(isDark, accent),
      home: const LandingPage(),
      routes: {
        '/login': (_) => const LoginScreen(),
      },
    );
  }
}
