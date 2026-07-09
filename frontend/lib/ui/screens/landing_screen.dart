import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/data/storage/storage_service.dart';
import 'package:keepsy/data/api/user_api.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/api/realtime_service.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/e2ee/epoch_processor.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/ui/screens/login_screen.dart';
import 'package:keepsy/ui/screens/main_shell.dart';

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
      // Fetch user profile and their albums concurrently
      final responses = await Future.wait([
        userService.getMe(),
        albumService.getMyAlbums(),
      ]);

      final userData = responses[0] as Map<String, dynamic>?;
      final userAlbums = responses[1] as List<dynamic>?;

      // Server doesnt return email or display name (M8 + M7) : load both from
      // local storage written at login. Null on a brand new install that came
      // straight to landing without going through login : harmless
      final cachedEmail = await storage.getEmail();
      final cachedName = await storage.getName();
      if (mounted) {
        final appState = context.read<AppState>();
        if (userData != null) {
          appState.setUserData(userData);
        }
        if (cachedEmail != null) {
          appState.setEmail(cachedEmail);
        }
        if (cachedName != null) {
          appState.setProfileName(cachedName);
        }
        if (userAlbums != null) {
          appState.setAlbums(userAlbums.cast());
        }

        // Capture providers up front : context isnt valid across the awaits
        // below, and we want to fire'n'forget the hygiene path so landing
        // navigates immediately after the cheap auth+user+albums fetches
        final identity = context.read<IdentityService>();
        final epochProcessor = context.read<EpochProcessor>();
        // Idempotent ('if (_active) return'); safe to call on every landing
        unawaited(context.read<RealtimeService>().connect());

        // D5 + D9 + §4.2 §9 cold start hygiene : rotate SPK if ≥30d, refill
        // OPKs up to target, catch up missed epoch_changed events
        //  all in the background, none of it gates navigation. UI
        // surfaces that need IK/LK/SPK await identity.cryptoReady (3.1)
        final List<Uint8List> albumIds = [];
        if (userAlbums != null) {
          for (final a in userAlbums) {
            final b = _uuidStringToBytes((a as AlbumModel).id);
            if (b != null) albumIds.add(b);
          }
        }
        unawaited(
            _runCryptoHygiene(identity, epochProcessor, appState, albumIds));
      }
    }

    if (!mounted) return;

    final destination = valid ? const MainShell() : const LoginScreen();

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

  // Runs cold start crypto hygiene off the navigation critical path. Album
  // detail screens watch AppState.isSyncing to render a "syncing keys"
  // placeholder until catchUpAll lands the MK
  Future<void> _runCryptoHygiene(
      IdentityService identity,
      EpochProcessor epochProcessor,
      AppState appState,
      List<Uint8List> albumIds) async {
    try {
      await identity.bootstrap();
    } catch (_) {/* logged via identity.cryptoReady error */}
    try {
      await identity.ensureSpkRotated();
    } catch (_) {/* best effort */}
    try {
      // trigger=kTargetOpkPool so the post-bootstrap pool (5) is force refilled
      // up to 20 immediately. Steady state callers (WS opk_low) use the default
      // trigger=kReplenishTrigger so they only refill on real consumption
      await identity.replenishOpks(
        target: kTargetOpkPool,
        trigger: kTargetOpkPool,
      );
    } catch (_) {/* best effort */}
    // _appState captured up front : the sync lifecycle outlives this screen
    // (fire'n'forget + immediate pushReplacement), so it MUST NOT be gated on
    // `mounted`. clearing after unmount is
    // safe and is the only thing that lifts the "Syncing keys" overlay
    await syncAlbumKeys(
      appState: appState,
      albumIds: albumIds,
      catchUp: epochProcessor.catchUpAll,
    );
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
    // Read the current default accent securely from AppState
    final accent = context.watch<AppState>().accent;

    return Scaffold(
      backgroundColor: const Color(0xFF000000), // Simple black screen
      body: Center(
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [accent, accent.withOpacity(0.6)],
            ),
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: accent.withOpacity(0.5),
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

// Drives the per album "Syncing encryption keys" overlay around a key catch up
// Mark on, run, clear in a finally : the overlay state lives in the app level
// AppState singleton and outlives the (fire'n'forget) screen that triggers it,
// so cleanup must NOT depend on any widget being mounted. Forgetting to clear
// (the prior `if (!mounted) return` bug) stranded the overlay forever
Future<void> syncAlbumKeys({
  required AppState appState,
  required List<Uint8List> albumIds,
  required Future<void> Function(List<Uint8List>) catchUp,
}) async {
  if (albumIds.isEmpty) return;
  final ids = albumIds.map(uuidStringFromBytes).toList();
  appState.markSyncing(ids);
  try {
    await catchUp(albumIds);
    // MKs are installed now : titles that setAlbums couldnt decrypt yet
    // (cold start before catch up) become resolvable
    appState.refreshAlbumNames();
  } catch (_) {
  } finally {
    for (final id in ids) {
      appState.clearSyncing(id);
    }
  }
}
