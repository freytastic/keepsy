import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/member_face.dart';
import 'package:keepsy/ui/widgets/pressable_scale.dart';

import 'album_copy.dart';

class AvatarMember {
  final String token;

  // Null until decryption completes
  final String? name;

  // Invited but no name published yet, so they have not opened the album
  final bool pending;

  const AvatarMember({required this.token, this.name, this.pending = false});
}

// Never derive display initials from member tokens
class MemberAvatars extends StatelessWidget {
  // Scopes avatar lookups; faces fall back to initials without it
  final String? albumId;
  final List<AvatarMember> members;
  final String? selectedToken;
  final ValueChanged<String> onTap;
  final VoidCallback? onAdd;

  const MemberAvatars({
    super.key,
    this.albumId,
    required this.members,
    required this.onTap,
    this.selectedToken,
    this.onAdd,
  });

  static const double _size = 27;
  static const double _overlap = -7;
  static const double _ring = 2.5;

  static const List<Color> palette = [
    Color(0xFFF4C7BF),
    Color(0xFFF6D2AB),
    Color(0xFFF0DFA9),
    Color(0xFFCFE0C6),
    Color(0xFFC6D4EC),
    Color(0xFFE9CDBE),
  ];

  // Token hashing keeps member colors stable across devices
  static Color hueFor(String token) {
    var hash = 0;
    for (final unit in token.codeUnits) {
      hash = (hash * 31 + unit) & 0x7FFFFFFF;
    }
    return palette[hash % palette.length];
  }

  static String initialFor(String? name) {
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return '·';
    return trimmed.characters.first.toUpperCase();
  }

  static const double _step = _size + _overlap;
  // The add button sits apart so it reads as an action, not a face
  static const double _addGap = 5;

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty && onAdd == null) return const SizedBox.shrink();
    final filtering = selectedToken != null;
    final faces = members.isEmpty ? 0 : (members.length - 1) * _step + _size;
    return SizedBox(
      height: _size,
      // Negative overlap requires explicit positioning
      width: faces + (onAdd == null ? 0 : _addGap + _size),
      child: Stack(
        children: [
          for (var i = 0; i < members.length; i++)
            Positioned(
              left: i * _step,
              child: members[i].pending
                  ? Semantics(
                      label: AlbumCopy.invitedPending,
                      child: const DashedCircle(
                        size: _size,
                        ring: _ring,
                      ),
                    )
                  : _Avatar(
                      albumId: albumId,
                      member: members[i],
                      dimmed: filtering && members[i].token != selectedToken,
                      onTap: () => onTap(members[i].token),
                    ),
            ),
          if (onAdd != null)
            Positioned(
              left: faces + (members.isEmpty ? 0 : _addGap),
              child: _AddFace(onTap: onAdd!),
            ),
        ],
      ),
    );
  }
}

class _AddFace extends StatelessWidget {
  final VoidCallback onTap;

  const _AddFace({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: AlbumCopy.addSomeone,
      child: PressableScale(
        key: const ValueKey('add-someone'),
        onTap: onTap,
        child: Container(
          width: MemberAvatars._size,
          height: MemberAvatars._size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: Warm.stoneFill,
            border: Border.all(color: Warm.ground, width: MemberAvatars._ring),
            boxShadow: [
              BoxShadow(
                  color: Warm.shadow(0.12),
                  blurRadius: 3,
                  offset: const Offset(0, 1)),
            ],
          ),
          child: const Icon(Icons.add_rounded, size: 14, color: Warm.inkSoft),
        ),
      ),
    );
  }
}

// A kept place with nothing to draw in it yet
class DashedCircle extends StatelessWidget {
  final double size;
  final double ring;
  final Widget? child;

  const DashedCircle(
      {super.key, required this.size, this.ring = 0, this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: ring == 0
          ? null
          : BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Warm.ground, width: ring),
            ),
      child: CustomPaint(
        size: Size.square(size - ring * 2),
        painter: const _Dashes(),
        child: SizedBox.square(
            dimension: size - ring * 2, child: Center(child: child)),
      ),
    );
  }
}

class _Dashes extends CustomPainter {
  const _Dashes();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..color = const Color(0x421C1917);
    final r = size.width / 2 - 0.65;
    final center = size.center(Offset.zero);
    const dashes = 14;
    const sweep = 2 * math.pi / dashes;
    for (var i = 0; i < dashes; i++) {
      canvas.drawArc(Rect.fromCircle(center: center, radius: r), i * sweep,
          sweep * 0.55, false, paint);
    }
  }

  @override
  bool shouldRepaint(_Dashes old) => false;
}

class _Avatar extends StatelessWidget {
  final String? albumId;
  final AvatarMember member;
  final bool dimmed;
  final VoidCallback onTap;

  const _Avatar({
    required this.albumId,
    required this.member,
    required this.dimmed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: dimmed ? 0.38 : 1,
        duration: Warm.quick,
        child: MemberFace(
          albumId: albumId,
          token: member.token,
          name: member.name,
          size: MemberAvatars._size,
          border: Border.all(color: Warm.ground, width: MemberAvatars._ring),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Warm.inkSoft,
            height: 1,
          ),
        ),
      ),
    );
  }
}
