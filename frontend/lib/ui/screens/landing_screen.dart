import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/data/storage/storage_service.dart';
import 'package:keepsy/data/api/user_api.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/api/realtime_service.dart';
import 'package:keepsy/data/shelf_sync.dart';
import 'package:keepsy/data/storage/media_catalog.dart';
import 'package:keepsy/diagnostics/trace.dart';
import 'package:keepsy/e2ee/epoch_processor.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/e2ee/rotation_recovery.dart';
import 'package:keepsy/ui/screens/onboarding_screen.dart';
import 'package:keepsy/ui/screens/main_shell.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';

class LandingPage extends StatefulWidget {
  const LandingPage({super.key});

  @override
  State<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends State<LandingPage> {
  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    final storage = StorageService();
    final userService = UserService();
    final albumService = AlbumService();
    final valid = await storage.isValid();

    if (valid) {
      // Server doesnt return email or display name (M8 + M7) : load both from
      // local storage written at login. Null on a brand new install that came
      // straight to landing without going through login : harmless
      final cachedEmail = await storage.getEmail();
      final cachedName = await storage.getName();
      final cachedUserId = await storage.getUserId();
      if (mounted) {
        final appState = context.read<AppState>();
        if (cachedEmail != null) appState.setEmail(cachedEmail);
        if (cachedName != null) appState.setProfileName(cachedName);
        // Photos sealed offline can be listed before the server answers
        if (cachedUserId != null) appState.setCachedUserId(cachedUserId);

        // Capture providers before the background awaits
        final identity = context.read<IdentityService>();
        final epochProcessor = context.read<EpochProcessor>();
        final catalog = context.read<AlbumCatalog>();
        final rotationRecovery = context.read<RotationRecoveryScheduler>();
        // Idempotent ('if (_active) return'); safe to call on every landing
        unawaited(context.read<RealtimeService>().connect());
        unawaited(_warmSession(
          userService: userService,
          albumService: albumService,
          catalog: catalog,
          appState: appState,
          identity: identity,
          epochProcessor: epochProcessor,
          rotationRecovery: rotationRecovery,
        ));
      }
    }

    if (!mounted) return;

    final destination = valid ? const MainShell() : const OnboardingScreen();

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 250),
        pageBuilder: (_, __, ___) => destination,
        transitionsBuilder: (_, a, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
          child: child,
        ),
      ),
    );
  }

  // Refresh network state after local navigation
  Future<void> _warmSession({
    required UserService userService,
    required AlbumService albumService,
    required AlbumCatalog catalog,
    required AppState appState,
    required IdentityService identity,
    required EpochProcessor epochProcessor,
    required RotationRecoveryScheduler rotationRecovery,
  }) async {
    final userData = await Trace.measure<Map<String, dynamic>?>(
      'coldstart.identity',
      userService.getMe,
    );
    if (userData != null) appState.setUserData(userData);

    await loadShelf(
      catalog: catalog,
      fetch: albumService.getMyAlbums,
      apply: appState.setAlbums,
    );

    // Crypto hygiene uses the best shelf available including offline state
    final albumIds = <Uint8List>[];
    for (final a in appState.albums) {
      final b = _uuidStringToBytes(a.id);
      if (b != null) albumIds.add(b);
    }
    await _runCryptoHygiene(
        identity, epochProcessor, rotationRecovery, appState, albumIds);
  }

  // Runs cold start crypto hygiene off the navigation critical path. Album
  // detail screens watch AppState.isSyncing to render a "syncing keys"
  // placeholder until catchUpAll lands the MK
  Future<void> _runCryptoHygiene(
      IdentityService identity,
      EpochProcessor epochProcessor,
      RotationRecoveryScheduler rotationRecovery,
      AppState appState,
      List<Uint8List> albumIds) async {
    try {
      await identity.bootstrap();
    } catch (_) {/* logged via identity.cryptoReady error */}
    // Reconcile and rotate under the shared SPK transition lock
    try {
      await identity.settleSpkState();
    } catch (_) {/* diagnostics are logged inside */}
    try {
      // Bootstrap fills the OPK target while steady state refills on consumption
      await identity.replenishOpks(
        target: kTargetOpkPool,
        trigger: kTargetOpkPool,
      );
    } catch (_) {/* best effort */}
    // Key sync outlives this screen and must clear its app-level state after unmount
    await syncAlbumKeys(
      appState: appState,
      albumIds: albumIds,
      catchUp: epochProcessor.catchUpAll,
    );
    // Rotating needs a settled identity and caught up album keys
    await rotationRecovery.checkAll(albumIds);
  }

  // 8-4-4-4-12 hex string -> 16 raw bytes. Returns null on malformed input
  // so callers (best effort cold start) skip the album rather than throw
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Warm.ground,
      body: Center(
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Warm.ctaTop, Warm.ctaBottom],
            ),
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: Warm.ctaTop.withValues(alpha: 0.18),
                blurRadius: 30,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: const Center(
            child: Text(
              'k',
              style: TextStyle(
                color: Colors.white,
                fontSize: 36,
                fontWeight: FontWeight.w800,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// 16B UUID -> canonical hex string. Matches the form the server uses for IDs
String uuidStringFromBytes(Uint8List b) {
  final s = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
      '-${s.substring(16, 20)}-${s.substring(20)}';
}

// Always clears app-level sync state even after the triggering screen unmounts
Future<void> syncAlbumKeys({
  required AppState appState,
  required List<Uint8List> albumIds,
  required Future<void> Function(List<Uint8List>) catchUp,
}) async {
  if (albumIds.isEmpty) return;
  final ids = albumIds.map(uuidStringFromBytes).toList();
  final span = Trace.start('sync.albumKeys', fields: {'albums': ids.length});
  appState.markSyncing(ids);

  // Release each album as soon as its key sync completes
  var cursor = 0;
  Future<void> worker() async {
    while (true) {
      final i = cursor++;
      if (i >= albumIds.length) return;
      try {
        await catchUp([albumIds[i]]);
      } catch (_) {
      } finally {
        appState.clearSyncing(ids[i]);
      }
    }
  }

  // Bound network fan-out across large shelves
  const maxConcurrent = 2;
  final workers = <Future<void>>[
    for (var i = 0; i < maxConcurrent && i < albumIds.length; i++) worker(),
  ];

  try {
    await Future.wait(workers);
    // MKs are installed now : titles that setAlbums couldnt decrypt yet
    // (cold start before catch up) become resolvable
    appState.refreshAlbumNames();
    span.end();
  } catch (e) {
    span.fail(Trace.reasonOf(e));
  } finally {
    // Clear IDs left by an unexpected worker failure
    for (final id in ids) {
      appState.clearSyncing(id);
    }
  }
}
