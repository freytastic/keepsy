import 'package:flutter/material.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/pressable_scale.dart';

import 'album_copy.dart';

class AlbumMenu extends StatelessWidget {
  final VoidCallback onSelectPhotos;
  final VoidCallback onDownloadAlbum;
  final VoidCallback onAlbumInfo;

  // Null while the people screen is unavailable
  final VoidCallback? onPeople;

  const AlbumMenu({
    super.key,
    required this.onSelectPhotos,
    required this.onDownloadAlbum,
    required this.onAlbumInfo,
    this.onPeople,
  });

  static Future<void> show(
    BuildContext context, {
    required VoidCallback onSelectPhotos,
    required VoidCallback onDownloadAlbum,
    required VoidCallback onAlbumInfo,
    VoidCallback? onPeople,
  }) =>
      Navigator.of(context).push(PageRouteBuilder<void>(
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.transparent,
        transitionDuration: Warm.springSnappy,
        pageBuilder: (_, __, ___) => AlbumMenu(
          onSelectPhotos: onSelectPhotos,
          onDownloadAlbum: onDownloadAlbum,
          onAlbumInfo: onAlbumInfo,
          onPeople: onPeople,
        ),
        transitionsBuilder: (_, a, __, child) {
          final curve = CurvedAnimation(parent: a, curve: Warm.easeOut);
          return FadeTransition(
            opacity: curve,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, -0.03),
                end: Offset.zero,
              ).animate(curve),
              child: ScaleTransition(
                alignment: Alignment.topRight,
                scale: Tween<double>(begin: 0.94, end: 1).animate(curve),
                child: child,
              ),
            ),
          );
        },
      ));

  void _pick(BuildContext context, VoidCallback action) {
    Navigator.of(context).pop();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).pop(),
          ),
        ),
        Positioned(
          top: top + 54,
          right: 20,
          child: _MenuCard(
            children: [
              _MenuItem(
                label: AlbumCopy.selectPhotos,
                onTap: () => _pick(context, onSelectPhotos),
              ),
              _MenuItem(
                label: AlbumCopy.downloadAlbum,
                onTap: () => _pick(context, onDownloadAlbum),
              ),
              _MenuItem(
                label: AlbumCopy.peopleAndSafety,
                onTap:
                    onPeople == null ? null : () => _pick(context, onPeople!),
              ),
              const _MenuSeparator(),
              _MenuItem(
                label: AlbumCopy.albumInfo,
                onTap: () => _pick(context, onAlbumInfo),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MenuCard extends StatelessWidget {
  final List<Widget> children;

  const _MenuCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        // Cap width because Positioned leaves it unbounded
        constraints: const BoxConstraints(minWidth: 196, maxWidth: 280),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          gradient: Warm.stoneFill,
          borderRadius: BorderRadius.circular(15),
          boxShadow: Warm.printShadowSmall,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;

  const _MenuItem({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return PressableScale(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w500,
                  color: enabled ? Warm.ink : Warm.inkFaint,
                ),
              ),
            ),
            if (!enabled) const _LaterBadge(),
          ],
        ),
      ),
    );
  }
}

class _LaterBadge extends StatelessWidget {
  const _LaterBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Warm.wellEmpty,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        AlbumCopy.laterBadge,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: Warm.inkFaint,
        ),
      ),
    );
  }
}

class _MenuSeparator extends StatelessWidget {
  const _MenuSeparator();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      color: Warm.inkGhost,
    );
  }
}
