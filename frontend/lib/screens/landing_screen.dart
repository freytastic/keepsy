import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/storage_service.dart';
import '../services/user_service.dart';
import 'login_screen.dart';
import 'main_shell.dart';

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
    final valid = await storage.isValid();

    if (valid) {
      // User has a valid token session, fetch their latest profile
      final userData = await userService.getMe();
      if (userData != null && mounted) {
        context.read<AppState>().setUserData(userData);
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
