import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/album_model.dart';
import '../providers/app_state.dart';
import '../services/album_service.dart';
import '../core/app_theme.dart';
import '../widgets/shared_widgets.dart';
import 'profile_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final dark = state.isDark;
    final accent = state.accent;

    return Scaffold(
      backgroundColor: K.bg(dark),
      body: Stack(
        children: [
          GlowOrbs(
            colors: [accent.withOpacity(0.6), const Color(0xFF6366f1)],
            opacity: dark ? 0.12 : 0.85,
          ),
          SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Header(dark: dark, accent: accent),
                _GreetingBar(dark: dark),
                Expanded(
                  child: state.albums.isEmpty
                      ? _Empty(dark: dark, accent: accent)
                      : _BentoGrid(
                    albums: state.albums,
                    dark: dark,
                    accent: accent,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// header

class _Header extends StatelessWidget {
  final bool dark;
  final Color accent;

  const _Header({required this.dark, required this.accent});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
      child: Row(
        children: [
          // Logo
          ShaderMask(
            shaderCallback: (b) => LinearGradient(
              colors: [Colors.white, accent],
            ).createShader(b),
            child: const Text(
              'keepsy',
              style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  letterSpacing: -1.2),
            ),
          ),
          const Spacer(),
          // Avatar — taps to profile
          GestureDetector(
            onTap: () => Navigator.of(context).push(
              PageRouteBuilder(
                pageBuilder: (_, _, _) => const ProfileScreen(),
                transitionsBuilder: (_, a, _, child) => SlideTransition(
                  position: Tween<Offset>(
                      begin: const Offset(1, 0), end: Offset.zero)
                      .animate(CurvedAnimation(
                      parent: a, curve: Curves.easeOutCubic)),
                  child: child,
                ),
                transitionDuration: const Duration(milliseconds: 350),
              ),
            ),
            child: UserAvatar(
              name: state.profileName,
              avatarUrl: state.avatarUrl,
              size: 36,
            ),
          ),
        ],
      ),
    );
  }
}

// greeting

class _GreetingBar extends StatelessWidget {
  final bool dark;

  const _GreetingBar({required this.dark});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good morning'
        : hour < 17
        ? 'Good afternoon'
        : 'Good evening';
    final firstName = state.profileName.split(' ').first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$greeting, $firstName 👋',
            style: TextStyle(
                color: K.t1(dark),
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4),
          ),
          const SizedBox(height: 4),
          Text(
            '${state.albums.length} albums · ${state.albums.fold(0, (int s, dynamic a) => s + a.totalPhotos as int)} memories',
            style: TextStyle(color: K.t3(dark), fontSize: 13),
          ),
        ],
      ),
    );
  }
}

// bento grido

class _BentoGrid extends StatelessWidget {
  final List<AlbumModel> albums;
  final bool dark;
  final Color accent;

  const _BentoGrid(
      {required this.albums, required this.dark, required this.accent});

  @override
  Widget build(BuildContext context) {
    final items = _buildBentoItems();

    return RefreshIndicator(
      color: accent,
      backgroundColor: K.cardCol(dark),
      onRefresh: () async {
        final newAlbums = await AlbumService().getMyAlbums();
        if (context.mounted) context.read<AppState>().setAlbums(newAlbums);
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                    (_, i) => items[i],
                childCount: items.length,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildBentoItems() {
    final rows = <Widget>[];
    int i = 0;
    int rowIdx = 0;

    while (i < albums.length) {
      final pattern = rowIdx % 3;

      if (pattern == 0) {
        // Row A: big (left 3/5) + 2 smalls stacked (right 2/5)
        final big = albums[i];
        final sm1 = i + 1 < albums.length ? albums[i + 1] : null;
        final sm2 = i + 2 < albums.length ? albums[i + 2] : null;

        rows.add(Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SizedBox(
            height: 280,
            child: Row(
              children: [
                Expanded(
                    flex: 3, child: _AlbumCard(album: big, dark: dark)),
                if (sm1 != null) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: Column(
                      children: [
                        Expanded(child: _AlbumCard(album: sm1, dark: dark)),
                        if (sm2 != null) ...[
                          const SizedBox(height: 12),
                          Expanded(child: _AlbumCard(album: sm2, dark: dark)),
                        ] else
                          const Expanded(child: SizedBox()),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ));
        i += sm2 != null ? 3 : sm1 != null ? 2 : 1;
      } else if (pattern == 1) {
        // Row B: two equal tiles
        final a1 = albums[i];
        final a2 = i + 1 < albums.length ? albums[i + 1] : null;

        rows.add(Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SizedBox(
            height: 180,
            child: Row(
              children: [
                Expanded(child: _AlbumCard(album: a1, dark: dark)),
                if (a2 != null) ...[
                  const SizedBox(width: 12),
                  Expanded(child: _AlbumCard(album: a2, dark: dark)),
                ],
              ],
            ),
          ),
        ));
        i += a2 != null ? 2 : 1;
      } else {
        // Row C: 2 smalls (left) + big (right)
        final sm1 = albums[i];
        final sm2 = i + 1 < albums.length ? albums[i + 1] : null;
        final big = i + 2 < albums.length ? albums[i + 2] : null;

        rows.add(Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SizedBox(
            height: 280,
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Column(
                    children: [
                      Expanded(child: _AlbumCard(album: sm1, dark: dark)),
                      if (sm2 != null) ...[
                        const SizedBox(height: 12),
                        Expanded(child: _AlbumCard(album: sm2, dark: dark)),
                      ] else
                        const Expanded(child: SizedBox()),
                    ],
                  ),
                ),
                if (big != null) ...[
                  const SizedBox(width: 12),
                  Expanded(
                      flex: 3, child: _AlbumCard(album: big, dark: dark)),
                ],
              ],
            ),
          ),
        ));
        i += big != null ? 3 : sm2 != null ? 2 : 1;
      }

      rowIdx++;
    }

    return rows;
  }
}

// album card

class _AlbumCard extends StatefulWidget {
  final AlbumModel album;
  final bool dark;

  const _AlbumCard({required this.album, required this.dark});

  @override
  State<_AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends State<_AlbumCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = K.gradColors(widget.album.gradientColors);
    final hasPhoto = widget.album.coverPhotoUrl != null &&
        widget.album.coverPhotoUrl!.isNotEmpty;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);

      // this will be used later when the album detail screen is implemented
      //   Navigator.of(context).push(PageRouteBuilder(
      //     pageBuilder: (_, __, ___) =>
      //         AlbumDetailScreen(albumId: widget.album.id),
      //     transitionsBuilder: (_, a, __, child) => SlideTransition(
      //       position: Tween<Offset>(
      //           begin: const Offset(1, 0), end: Offset.zero)
      //           .animate(
      //           CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      //       child: child,
      //     ),
      //     transitionDuration: const Duration(milliseconds: 380),
      //   ));
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 130),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Background
              hasPhoto
                  ? Image.network(widget.album.coverPhotoUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _Gradient(colors: colors))
                  : _Gradient(colors: colors),

              // Vignette
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.72),
                    ],
                    stops: const [0.35, 1.0],
                  ),
                ),
              ),

              // Emoji when no photo
              if (!hasPhoto)
                Positioned(
                  top: 18,
                  right: 18,
                  child: Text(widget.album.emoji,
                      style: const TextStyle(fontSize: 32)),
                ),

              // Info
              Positioned(
                left: 14,
                right: 14,
                bottom: 14,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.album.collaborators.isNotEmpty) ...[
                      _CollabStack(
                          collabs:
                          widget.album.collaborators.take(3).toList()),
                      const SizedBox(height: 6),
                    ],
                    Text(
                      widget.album.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Icon(Icons.photo_library_outlined,
                            color: Colors.white54, size: 11),
                        const SizedBox(width: 4),
                        Text(
                          '${widget.album.totalPhotos} photos',
                          style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontWeight: FontWeight.w400),
                        ),
                        if (widget.album.collaborators.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          const Text('·',
                              style: TextStyle(
                                  color: Colors.white38, fontSize: 11)),
                          const SizedBox(width: 8),
                          const Icon(Icons.people_outline_rounded,
                              color: Colors.white54, size: 11),
                          const SizedBox(width: 4),
                          Text(
                            '${widget.album.collaborators.length}',
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 11),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Gradient extends StatelessWidget {
  final List<Color> colors;
  const _Gradient({required this.colors});

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      ),
    ),
  );
}

class _CollabStack extends StatelessWidget {
  final List<Collaborator> collabs;
  const _CollabStack({required this.collabs});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 22,
      width: math.min(collabs.length * 16.0 + 6, 54),
      child: Stack(
        children: List.generate(collabs.length, (i) {
          final c = collabs[i];
          return Positioned(
            left: i * 16.0,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient:
                LinearGradient(colors: K.gradColors(c.gradientColors)),
                border: Border.all(color: Colors.black, width: 1.5),
              ),
              child: Center(
                child: Text(c.initials[0],
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final bool dark;
  final Color accent;

  const _Empty({required this.dark, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              color: accent.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: const Center(
                child: Text('📷', style: TextStyle(fontSize: 40))),
          ),
          const SizedBox(height: 20),
          Text('No albums yet',
              style: TextStyle(
                  color: K.t1(dark),
                  fontSize: 20,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text('Tap + below to create your first album',
              style: TextStyle(color: K.t3(dark), fontSize: 14)),
        ],
      ),
    );
  }
}