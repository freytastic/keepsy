import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../core/app_theme.dart';
import 'home_screen.dart';
import 'notifications_screen.dart';
import 'create_album_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _tab = 0;

  void _switchTab(int i) {
    HapticFeedback.selectionClick();
    setState(() => _tab = i);
  }

  Future<void> _openCreate() async {
    HapticFeedback.mediumImpact();
    await Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, _, _) => const CreateAlbumScreen(),
        transitionsBuilder: (_, a, _, child) => SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
              .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 250),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final dark = state.isDark;
    final accent = state.accent;

    return Scaffold(
      backgroundColor: K.bg(dark),
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // main content
          IndexedStack(
            index: _tab,
            children: const [
              HomeScreen(),
              NotificationsScreen(),
            ],
          ),
          // top gradient fade – soft edge look
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: MediaQuery.of(context).padding.top + 32,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      K.bg(dark),
                      K.bg(dark).withOpacity(0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _BottomBar(
        current: _tab,
        accent: accent,
        dark: dark,
        hasNotifications: state.hasUnreadNotifications,
        onHome: () => _switchTab(0),
        onNotifs: () => _switchTab(1),
        onCreate: _openCreate,
      ),
    );
  }
}

// ─── Bottom bar ───────────────────────────────────────────────────────────────

class _BottomBar extends StatelessWidget {
  final int current;
  final Color accent;
  final bool dark;
  final bool hasNotifications;
  final VoidCallback onHome;
  final VoidCallback onNotifs;
  final VoidCallback onCreate;

  const _BottomBar({
    required this.current,
    required this.accent,
    required this.dark,
    required this.hasNotifications,
    required this.onHome,
    required this.onNotifs,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72 + MediaQuery.of(context).padding.bottom,
      decoration: BoxDecoration(
        color: dark
            ? const Color(0xFF0D0D0F).withOpacity(0.92)
            : Colors.white.withOpacity(0.92),
        border: Border(
          top: BorderSide(
            color: dark
                ? Colors.white.withOpacity(0.06)
                : Colors.black.withOpacity(0.06),
            width: 0.5,
          ),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
        child: Row(
          children: [
            // Home
            Expanded(
              child: _NavBtn(
                icon: Icons.home_rounded,
                label: 'Home',
                active: current == 0,
                accent: accent,
                dark: dark,
                onTap: onHome,
              ),
            ),
            // Centre + button
            _CreateBtn(accent: accent, onTap: onCreate),
            // Activity
            Expanded(
              child: _NavBtn(
                icon: Icons.notifications_outlined,
                label: 'Activity',
                active: current == 1,
                accent: accent,
                dark: dark,
                onTap: onNotifs,
                showBadge: hasNotifications,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color accent;
  final bool dark;
  final VoidCallback onTap;
  final bool showBadge;

  const _NavBtn({
    required this.icon,
    required this.label,
    required this.active,
    required this.accent,
    required this.dark,
    required this.onTap,
    this.showBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? accent : K.t3(dark);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 56,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedScale(
              scale: active ? 1.1 : 1.0,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(icon, color: color, size: 24),
                  if (showBadge)
                    Positioned(
                      top: -2,
                      right: -4,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: const Color(0xFFEF4444),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: dark
                                ? const Color(0xFF0D0D0F)
                                : Colors.white,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 180),
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                letterSpacing: 0.1,
              ),
              child: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreateBtn extends StatefulWidget {
  final Color accent;
  final VoidCallback onTap;

  const _CreateBtn({required this.accent, required this.onTap});

  @override
  State<_CreateBtn> createState() => _CreateBtnState();
}

class _CreateBtnState extends State<_CreateBtn>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 3))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: AnimatedScale(
          scale: _pressed ? 0.92 : 1.0,
          duration: const Duration(milliseconds: 120),
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (_, _) => Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                    colors: [widget.accent, widget.accent.withOpacity(0.75)]),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: widget.accent.withOpacity(0.55),
                    blurRadius: 20 + _ctrl.value * 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Icon(Icons.add_rounded, color: Colors.white, size: 30),
            ),
          ),
        ),
      ),
    );
  }
}