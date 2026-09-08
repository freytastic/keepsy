import 'package:flutter/material.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/pressable_scale.dart';

class AvatarMember {
  final String token;

  // Null until decryption completes
  final String? name;

  const AvatarMember({required this.token, this.name});
}

// Never derive display initials from member tokens
class MemberAvatars extends StatelessWidget {
  final List<AvatarMember> members;
  final String? selectedToken;
  final ValueChanged<String> onTap;

  const MemberAvatars({
    super.key,
    required this.members,
    required this.onTap,
    this.selectedToken,
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

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) return const SizedBox.shrink();
    final filtering = selectedToken != null;
    return SizedBox(
      height: _size,
      // Negative overlap requires explicit positioning
      width: (members.length - 1) * _step + _size,
      child: Stack(
        children: [
          for (var i = 0; i < members.length; i++)
            Positioned(
              left: i * _step,
              child: _Avatar(
                member: members[i],
                dimmed: filtering && members[i].token != selectedToken,
                onTap: () => onTap(members[i].token),
              ),
            ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final AvatarMember member;
  final bool dimmed;
  final VoidCallback onTap;

  const _Avatar({
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
        child: Container(
          width: MemberAvatars._size,
          height: MemberAvatars._size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: MemberAvatars.hueFor(member.token),
            shape: BoxShape.circle,
            border: Border.all(color: Warm.ground, width: MemberAvatars._ring),
          ),
          child: Text(
            MemberAvatars.initialFor(member.name),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Warm.inkSoft,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
