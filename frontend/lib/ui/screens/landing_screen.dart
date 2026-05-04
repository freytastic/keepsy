import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/data/storage/storage_service.dart';
import 'package:keepsy/data/api/user_api.dart';
import 'package:keepsy/data/api/album_api.dart';
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

      if (mounted) {
        if (userData != null) {
          context.read<AppState>().setUserData(userData);
        }
        if (userAlbums != null) {
          context.read<AppState>().setAlbums(userAlbums.cast());
        }

        // D5 + D9 cold-start hygiene : rotate SPK if ≥30d and refill OPKs
        // if the pool dropped below the trigger. Both are best effort and
        // must never block landing : a network blip shouldn't bounce the
        // user back to login
        final identity = context.read<IdentityService>();
        try {
          await identity.ensureSpkRotated();
        } catch (_) {/* logged elsewhere; landing must not gate */}
        try {
          await identity.replenishOpks();
        } catch (_) {/* same */}
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
