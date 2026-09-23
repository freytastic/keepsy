import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:keepsy/data/models/avatar_ref.dart';
import 'package:keepsy/data/storage/avatar_cache.dart';
import 'package:keepsy/data/storage/own_avatar_store.dart';
import 'package:keepsy/domain/avatar/avatar_publisher.dart';
import 'package:keepsy/ui/album/member_avatars.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';

// A member's face in one album: their decrypted avatar once it has loaded,
// otherwise their stable colour and initial (which is totally bleh :/)
class MemberFace extends StatelessWidget {
  // Null draws the initial only, for places with no album context
  final String? albumId;
  final String token;
  final String? name;
  final double size;
  final TextStyle style;
  final Color? color;
  final BoxBorder? border;

  const MemberFace({
    super.key,
    required this.albumId,
    required this.token,
    required this.name,
    required this.size,
    required this.style,
    this.color,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    return FaceCircle(
      size: size,
      color: color ?? MemberAvatars.hueFor(token),
      border: border,
      photo: memberPhoto(context, albumId, token),
      child: Text(MemberAvatars.initialFor(name), style: style),
    );
  }
}

// The member's decrypted avatar, or null until one has loaded. Every select
// runs on every build so the dependency set stays fixed
Uint8List? memberPhoto(BuildContext context, String? albumId, String token) {
  final id = albumId;
  final self = context.select<AppState?, bool>(
      (s) => id != null && s?.selfMemberToken(id) == token);
  final own = context.select<OwnAvatarStore?, Uint8List?>(
      (o) => o?.state == OwnAvatarState.set ? o?.jpeg : null);
  final ref = context.select<AppState?, AvatarRef?>(
      (s) => id == null ? null : s?.avatarOf(id, token));
  final cached = context.select<AvatarCache?, Uint8List?>((c) =>
      id == null || ref == null ? null : c?.peek(id, token, ref.avatarId));
  // Our own face comes from this phone, not from the album's copy
  if (self) return own;
  if (id != null && ref != null && cached == null) {
    context.read<AvatarCache?>()?.ensure(id, token, ref);
  }
  return cached;
}

class FaceCircle extends StatelessWidget {
  final double size;
  final Color color;
  final Gradient? gradient;
  final BoxBorder? border;
  final List<BoxShadow>? shadow;
  final Uint8List? photo;
  final Widget child;

  const FaceCircle({
    super.key,
    required this.size,
    required this.color,
    required this.child,
    this.gradient,
    this.border,
    this.shadow,
    this.photo,
  });

  @override
  Widget build(BuildContext context) {
    final p = photo;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        gradient: p == null ? gradient : null,
        shape: BoxShape.circle,
        border: border,
        boxShadow: shadow,
      ),
      child: ClipOval(
        child: AnimatedSwitcher(
          duration: Warm.quick,
          child: p == null
              ? Center(key: const ValueKey('initial'), child: child)
              : Image.memory(
                  p,
                  key: ObjectKey(p),
                  fit: BoxFit.cover,
                  width: size,
                  height: size,
                  cacheWidth: (size *
                          (MediaQuery.maybeDevicePixelRatioOf(context) ?? 2))
                      .round(),
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, __, ___) => Center(child: child),
                ),
        ),
      ),
    );
  }
}
