import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/data/storage/storage_service.dart';
import 'package:miuchio/data/api/user_api.dart';
import 'package:miuchio/data/api/album_api.dart';
import 'package:miuchio/data/api/realtime_service.dart';
import 'package:miuchio/data/shelf_sync.dart';
import 'package:miuchio/data/storage/media_catalog.dart';
import 'package:miuchio/diagnostics/trace.dart';
import 'package:miuchio/e2ee/epoch_processor.dart';
import 'package:miuchio/e2ee/identity.dart';
import 'package:miuchio/data/api/session_refresher.dart';
import 'package:miuchio/main.dart' show rootNavigatorKey;
import 'package:miuchio/domain/account/account_deletion.dart' show TerminalWipe;
import 'package:miuchio/domain/account/account_gate.dart';
import 'package:miuchio/domain/account/sign_in_gate.dart';
import 'package:miuchio/e2ee/rotation_recovery.dart';
import 'package:miuchio/ui/screens/account_conflict_screens.dart';
import 'package:miuchio/ui/screens/erase_installation_flow.dart';
import 'package:miuchio/ui/screens/start_deletion_flow.dart';
import 'package:miuchio/ui/screens/onboarding_screen.dart';
import 'package:miuchio/ui/screens/main_shell.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/camera_stage.dart';

class LandingPage extends StatefulWidget {
  const LandingPage({super.key});

  @override
  State<LandingPage> createState() => _LandingPageState();
}

// Reconcile outside the widget lifetime so refusals still discard credentials
Future<AccountGateOutcome> reconcileAccount({
  required SignInGate gate,
  required String? userId,
  required Future<void> Function() discardSession,
}) async {
  AccountGateOutcome outcome;
  if (userId == null) {
    outcome = AccountGateOutcome.connectionRequired;
  } else {
    try {
      outcome = await gate.resolve(userId);
    } catch (_) {
      outcome = AccountGateOutcome.connectionRequired;
    }
  }
  if (!AccountGate.admitsShelf(outcome) &&
      !AccountGate.retainsSession(outcome)) {
    await discardSession();
  }
  return outcome;
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
      // Restore email and display name from local storage because /me omits them
      final cachedEmail = await storage.getEmail();
      final cachedName = await storage.getName();
      final cachedUserId = await storage.getUserId();
      if (mounted) {
        final appState = context.read<AppState>();
        if (cachedEmail != null) appState.setEmail(cachedEmail);
        if (cachedName != null) appState.setProfileName(cachedName);
        if (cachedUserId != null) appState.setCachedUserId(cachedUserId);

        final identity = context.read<IdentityService>();
        final epochProcessor = context.read<EpochProcessor>();
        final catalog = context.read<AlbumCatalog>();
        final rotationRecovery = context.read<RotationRecoveryScheduler>();
        final gate = context.read<SignInGate>();
        final wipe = context.read<TerminalWipe>();
        unawaited(context.read<RealtimeService>().connect());
        unawaited(_warmSession(
          userService: userService,
          albumService: albumService,
          catalog: catalog,
          appState: appState,
          identity: identity,
          epochProcessor: epochProcessor,
          rotationRecovery: rotationRecovery,
          gate: gate,
          wipe: wipe,
        ));
      }
    }

    if (!mounted) return;

    // Hide clip preparation behind the route fade
    if (!valid) CameraStage.prewarm();
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

  Future<void> _warmSession({
    required UserService userService,
    required AlbumService albumService,
    required AlbumCatalog catalog,
    required AppState appState,
    required IdentityService identity,
    required EpochProcessor epochProcessor,
    required RotationRecoveryScheduler rotationRecovery,
    required SignInGate gate,
    required TerminalWipe wipe,
  }) async {
    try {
      await SessionRefresher().renewIfDue();
    } catch (_) {
    }

    final userData = await Trace.measure<Map<String, dynamic>?>(
      'coldstart.identity',
      userService.getMe,
    );
    if (userData != null) appState.setUserData(userData);

    // Use the cached account ID when /users/me is unavailable
    final userId =
        userData?['id'] as String? ?? await StorageService().getUserId();
    final outcome = await reconcileAccount(
      gate: gate,
      userId: userId,
      discardSession: StorageService().deleteAuth,
    );
    if (!AccountGate.admitsShelf(outcome)) {
      _presentGateRefusal(outcome, wipe);
      return;
    }

    await loadShelf(
      catalog: catalog,
      fetch: albumService.getMyAlbums,
      restore: appState.setAlbums,
      apply: appState.applyListing,
    );

    final albumIds = <Uint8List>[];
    for (final a in appState.albums) {
      final b = _uuidStringToBytes(a.id);
      if (b != null) albumIds.add(b);
    }
    await _runCryptoHygiene(
        identity, epochProcessor, rotationRecovery, appState, albumIds);
  }

  // Use the root navigator after Landing has been replaced
  void _presentGateRefusal(AccountGateOutcome outcome, TerminalWipe wipe) {
    final Widget screen = switch (outcome) {
      AccountGateOutcome.lostDevice => AccountKeysLostScreen(
          onDismiss: (_) => SystemNavigator.pop(),
          onDeleteAndStartOver: startDeletionFlow,
        ),
      AccountGateOutcome.connectionRequired => const ConnectionRequiredScreen(),
      _ => AccountBelongsToAnotherScreen(
          onUseOwnerAccount: (ctx) => Navigator.of(ctx).pushAndRemoveUntil(
            MaterialPageRoute<void>(builder: (_) => const OnboardingScreen()),
            (_) => false,
          ),
          onEraseInstallation: (ctx) => confirmAndEraseInstallation(ctx, wipe),
        ),
    };
    rootNavigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => screen),
      (_) => false,
    );
  }

  // Run key setup after navigation while AppState tracks album sync
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

  // Malformed album IDs are skipped during background sync
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

String uuidStringFromBytes(Uint8List b) {
  final s = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
      '-${s.substring(16, 20)}-${s.substring(20)}';
}

Future<void> syncAlbumKeys({
  required AppState appState,
  required List<Uint8List> albumIds,
  required Future<void> Function(List<Uint8List>) catchUp,
}) async {
  if (albumIds.isEmpty) return;
  final ids = albumIds.map(uuidStringFromBytes).toList();
  final span = Trace.start('sync.albumKeys', fields: {'albums': ids.length});
  appState.markSyncing(ids);

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

  const maxConcurrent = 2;
  final workers = <Future<void>>[
    for (var i = 0; i < maxConcurrent && i < albumIds.length; i++) worker(),
  ];

  try {
    await Future.wait(workers);
    // Installed keys may unlock previously unreadable titles
    appState.refreshAlbumNames();
    span.end();
  } catch (e) {
    span.fail(Trace.reasonOf(e));
  } finally {
    // Release sync state after unexpected worker failures
    for (final id in ids) {
      appState.clearSyncing(id);
    }
  }
}
