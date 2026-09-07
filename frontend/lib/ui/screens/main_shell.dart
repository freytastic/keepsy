import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/screens/album_detail_screen.dart';
import 'package:keepsy/ui/create/create_album_screen.dart';
import 'package:keepsy/ui/screens/notifications_screen.dart';
import 'package:keepsy/ui/shelf/profile_screen.dart';
import 'package:keepsy/ui/shelf/shelf_screen.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';

class MainShell extends StatelessWidget {
  const MainShell({super.key});

  static Route<T> _slide<T>(Widget page,
      {Offset from = const Offset(1, 0), bool opaque = true}) {
    return PageRouteBuilder<T>(
      opaque: opaque,
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, a, __, child) => SlideTransition(
        position: Tween<Offset>(begin: from, end: Offset.zero)
            .animate(CurvedAnimation(parent: a, curve: Warm.easeSoft)),
        child: child,
      ),
      transitionDuration: Warm.springSnappy,
    );
  }

  Future<void> _create(BuildContext context) async {
    HapticFeedback.mediumImpact();
    final appState = context.read<AppState>();
    await Navigator.of(context).push(_slide(const CreateAlbumScreen(),
        from: const Offset(0, 1), opaque: false));
    await _refresh(appState);
  }

  Future<void> _openAlbum(BuildContext context, AlbumModel album) async {
    final appState = context.read<AppState>();
    await Navigator.of(context).push(_slide(AlbumDetailScreen(album: album)));
    // Refresh without delaying shelf development
    unawaited(_refresh(appState));
  }

  // Keep stale albums when refresh fails
  static Future<void> _refresh(AppState appState) async {
    final fresh = await AlbumService().getMyAlbums();
    if (fresh != null) appState.setAlbums(fresh);
  }

  @override
  Widget build(BuildContext context) {
    return ShelfScreen(
      onOpenProfile: () => Navigator.of(context)
          .push(_slide(const ProfileScreen(), from: const Offset(-1, 0))),
      onOpenAlbum: (album) => _openAlbum(context, album),
      onCreateAlbum: () => _create(context),
      onOpenActivity: () =>
          Navigator.of(context).push(_slide(const NotificationsScreen())),
    );
  }
}
