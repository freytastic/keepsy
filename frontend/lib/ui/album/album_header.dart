import 'package:flutter/material.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/pressable_scale.dart';

import 'album_copy.dart';
import 'member_avatars.dart';

class AlbumHeader extends StatelessWidget {
  final String title;
  final String summary;
  final List<AvatarMember> members;
  final String? filterToken;
  final String? filterName;
  final int filterCount;
  final ValueChanged<String> onTapMember;
  final VoidCallback onClearFilter;

  const AlbumHeader({
    super.key,
    required this.title,
    required this.summary,
    required this.members,
    required this.onTapMember,
    required this.onClearFilter,
    this.filterToken,
    this.filterName,
    this.filterCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: titleStyle),
          const SizedBox(height: 7),
          Text(summary,
              style: const TextStyle(fontSize: 12.5, color: Warm.inkSoft)),
          if (members.isNotEmpty) ...[
            const SizedBox(height: 17),
            MemberAvatars(
              members: members,
              selectedToken: filterToken,
              onTap: onTapMember,
            ),
          ],
          if (filterToken != null) ...[
            const SizedBox(height: 12),
            _FilterChip(
              label: AlbumCopy.filteredBy(filterName, filterCount),
              onClear: onClearFilter,
            ),
          ],
        ],
      ),
    );
  }

  static const titleStyle = TextStyle(
    fontSize: 25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.65,
    height: 1.14,
    color: Warm.ink,
  );
}

class _FilterChip extends StatelessWidget {
  final String label;
  final VoidCallback onClear;

  const _FilterChip({required this.label, required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: PressableScale(
        onTap: onClear,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Warm.wellEmpty,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Warm.ink)),
              const SizedBox(width: 6),
              const Icon(Icons.close_rounded, size: 13, color: Warm.inkSoft),
            ],
          ),
        ),
      ),
    );
  }
}

class AlbumTopBar extends StatelessWidget {
  final String title;
  final bool visible;
  final VoidCallback onBack;
  final VoidCallback onMore;

  const AlbumTopBar({
    super.key,
    required this.title,
    required this.visible,
    required this.onBack,
    required this.onMore,
  });

  static const barHeight = 62.0;

  @override
  Widget build(BuildContext context) {
    // The gradient still runs full bleed so content fades out behind the
    // status bar; only the row is pushed clear of it
    final topInset = MediaQuery.paddingOf(context).top;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: Warm.quick,
        child: Container(
          height: barHeight + topInset,
          padding: EdgeInsets.only(left: 16, right: 16, top: topInset),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xF7F6F3EE),
                Color(0xF0F6F3EE),
                Color(0x00F6F3EE),
              ],
              stops: [0, 0.62, 1],
            ),
          ),
          child: Row(
            children: [
              AlbumIconButton(
                icon: Icons.chevron_left_rounded,
                tooltip: AlbumCopy.back,
                onTap: onBack,
              ),
              Expanded(
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Warm.ink),
                ),
              ),
              AlbumIconButton(
                icon: Icons.more_horiz_rounded,
                tooltip: AlbumCopy.more,
                onTap: onMore,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AlbumIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const AlbumIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Tooltip(
        message: tooltip,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(icon, size: 24, color: Warm.ink),
        ),
      ),
    );
  }
}
