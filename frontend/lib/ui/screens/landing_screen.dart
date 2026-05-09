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

        // D5 + D9 + §4.2 §9 cold start hygiene : rotate SPK if ≥30d, refill
        // OPKs if pool dropped below trigger, catch up missed epoch_changed
        // events. All best effort and must never block landing : a network
        // blip shouldn't bounce the user back to login
        // Capture providers up front so the post await dispatch doesnt re
        // read context across async gaps
        final identity = context.read<IdentityService>();
        final epochProcessor = context.read<EpochProcessor>();
        // Idempotent ('if (_active) return'); safe to call on every landing
        unawaited(context.read<RealtimeService>().connect());
        try {
          await identity.ensureSpkRotated();
        } catch (_) {/* logged elsewhere; landing must not gate */}
        try {
          await identity.replenishOpks();
        } catch (_) {/* same */}

        if (userAlbums != null && userAlbums.isNotEmpty) {
          final ids = <Uint8List>[];
          for (final a in userAlbums) {
            final b = _uuidStringToBytes((a as AlbumModel).id);
            if (b != null) ids.add(b);
          }
          if (ids.isNotEmpty) {
            try {
              await epochProcessor.catchUpAll(ids);
            } catch (_) {/* same hygiene as SPK/OPK */}
          }
        }
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
