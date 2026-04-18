import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../core/app_theme.dart';
import '../services/user_service.dart';
import '../widgets/shared_widgets.dart';
import 'login_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late TextEditingController _nameCtrl;
  bool _editingName = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl =
        TextEditingController(text: context.read<AppState>().profileName);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final img = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (img != null && mounted) {
      // Temporarily set to local path to stop compile errors.
      // S3 Network hook goes here.
      context.read<AppState>().setProfileAvatar(img.path);
      // TODO: Implement S3 network upload flow and updateMe({'avatar_key': ...}) 
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final dark = state.isDark;
    final accent = state.accent;
    final totalPhotos =
    state.albums.fold(0, (int s, dynamic a) => s + a.totalPhotos as int);

    return Scaffold(
      backgroundColor: K.bg(dark),
      body: Stack(
        children: [
          GlowOrbs(
              colors: [accent.withOpacity(0.6), const Color(0xFF818cf8)],
              opacity: 0.10),
          SafeArea(
            bottom: false,
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title
                  Text('Profile',
                      style: TextStyle(
                          color: K.t1(dark),
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5)),

                  const SizedBox(height: 32),

                  // Avatar + name card
                  GlassCard(
                    dark: dark,
                    radius: BorderRadius.circular(24),
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        Stack(
                          children: [
                            GestureDetector(
                              onTap: _pickAvatar,
                              child: UserAvatar(
                                name: state.profileName,
                                avatarUrl: state.avatarUrl,
                                size: 72,
                              ),
                            ),
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  color: accent,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: K.cardCol(dark), width: 2),
                                ),
                                child: const Icon(
                                    Icons.camera_alt_rounded,
                                    color: Colors.white,
                                    size: 12),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _editingName
                                  ? TextField(
                                controller: _nameCtrl,
                                style: TextStyle(
                                    color: K.t1(dark),
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700),
                                decoration: InputDecoration(
                                  border: InputBorder.none,
                                  isDense: true,
                                  contentPadding: EdgeInsets.zero,
                                  hintStyle: TextStyle(
                                      color: K.t3(dark)),
                                ),
                                onSubmitted: (v) async {
                                  state.setProfileName(v);
                                  UserService().updateMe({'name': v});
                                  setState(
                                          () => _editingName = false);
                                },
                                autofocus: true,
                              )
                                  : Row(
                                children: [
                                  Text(
                                    state.profileName,
                                    style: TextStyle(
                                        color: K.t1(dark),
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    onTap: () => setState(() => _editingName = true),
                                    child: Icon(Icons.edit_rounded, size: 16, color: K.t3(dark)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(state.email ?? '',
                                  style: TextStyle(
                                      color: K.t3(dark), fontSize: 13)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Stats
                  Row(
                    children: [
                      _StatCard(
                          label: 'Albums',
                          value: '${state.albums.length}',
                          icon: Icons.photo_album_outlined,
                          dark: dark,
                          accent: accent),
                      const SizedBox(width: 10),
                      _StatCard(
                          label: 'Photos',
                          value: '$totalPhotos',
                          icon: Icons.photo_library_outlined,
                          dark: dark,
                          accent: accent),
                      const SizedBox(width: 10),
                      _StatCard(
                          label: 'People',
                          value: _uniqueCollabCount(state).toString(),
                          icon: Icons.people_outline_rounded,
                          dark: dark,
                          accent: accent),
                    ],
                  ),

                  const SizedBox(height: 32),

                  _SectionTitle('Appearance', dark),
                  const SizedBox(height: 14),

                  // Theme toggle
                  GlassCard(
                    dark: dark,
                    radius: BorderRadius.circular(20),
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      children: [
                        _ThemeChip(
                          label: 'Dark',
                          selected: dark,
                          accent: accent,
                          dark: dark,
                          onTap: () {
                            state.setTheme(true);
                            UserService().updateMe({'theme': 'dark'});
                          },
                        ),
                        _ThemeChip(
                          label: 'Light',
                          selected: !dark,
                          accent: accent,
                          dark: dark,
                          onTap: () {
                            state.setTheme(false);
                            UserService().updateMe({'theme': 'light'});
                          },
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Accent colors
                  GlassCard(
                    dark: dark,
                    radius: BorderRadius.circular(20),
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Accent Color',
                            style: TextStyle(
                                color: K.t1(dark),
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 14),
                        Row(
                          mainAxisAlignment:
                          MainAxisAlignment.spaceBetween,
                          children: K.accentOptions.map((c) {
                            final sel = state.accent.value == c.value;
                            return GestureDetector(
                              onTap: () {
                                state.setAccent(c);
                                final hex = '#${c.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
                                UserService().updateMe({'accent_color': hex});
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: c,
                                  shape: BoxShape.circle,
                                  border: sel
                                      ? Border.all(
                                      color: Colors.white, width: 3)
                                      : null,
                                  boxShadow: sel
                                      ? [
                                    BoxShadow(
                                        color:
                                        c.withOpacity(0.6),
                                        blurRadius: 14,
                                        offset:
                                        const Offset(0, 4))
                                  ]
                                      : null,
                                ),
                                child: sel
                                    ? const Icon(Icons.check_rounded,
                                    color: Colors.white, size: 18)
                                    : null,
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),

                  _SectionTitle('Account', dark),
                  const SizedBox(height: 14),

                  // Sign out
                  GestureDetector(
                    onTap: () {
                      Navigator.of(context).pushAndRemoveUntil(
                        PageRouteBuilder(
                          pageBuilder: (_, __, ___) => const LoginScreen(),
                          transitionsBuilder: (_, a, __, child) =>
                              FadeTransition(opacity: a, child: child),
                          transitionDuration:
                          const Duration(milliseconds: 400),
                        ),
                            (_) => false,
                      );
                    },
                    child: Container(
                      width: double.infinity,
                      height: 52,
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: Colors.red.withOpacity(0.25)),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.logout_rounded,
                              color: Colors.red, size: 18),
                          SizedBox(width: 10),
                          Text('Sign Out',
                              style: TextStyle(
                                  color: Colors.red,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  Center(
                    child: Text('Keepsy v1.0.0',
                        style: TextStyle(
                            color: K.t3(dark), fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  int _uniqueCollabCount(AppState state) {
    final names = <String>{};
    for (final a in state.albums) {
      for (final c in a.collaborators) {
        names.add(c.name);
      }
    }
    return names.length;
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final bool dark;
  final Color accent;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.dark,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GlassCard(
        dark: dark,
        radius: BorderRadius.circular(18),
        padding:
        const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        child: Column(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: accent.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: accent, size: 16),
            ),
            const SizedBox(height: 8),
            Text(value,
                style: TextStyle(
                    color: K.t1(dark),
                    fontSize: 20,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(color: K.t3(dark), fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final bool dark;

  const _SectionTitle(this.text, this.dark);

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: TextStyle(
            color: K.t3(dark),
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8));
  }
}

class _ThemeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color accent;
  final bool dark;
  final VoidCallback onTap;

  const _ThemeChip({
    required this.label,
    required this.selected,
    required this.accent,
    required this.dark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 46,
          margin: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: selected ? accent : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            boxShadow: selected
                ? [
              BoxShadow(
                  color: accent.withOpacity(0.35),
                  blurRadius: 12,
                  offset: const Offset(0, 3))
            ]
                : null,
          ),
          child: Center(
            child: Text(label,
                style: TextStyle(
                    color: selected ? Colors.white : K.t2(dark),
                    fontSize: 14,
                    fontWeight: selected
                        ? FontWeight.w600
                        : FontWeight.w400)),
          ),
        ),
      ),
    );
  }
}