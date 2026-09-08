import 'package:flutter/material.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/foot_bar.dart';
import 'package:keepsy/ui/widgets/pressable_scale.dart';

import 'album_copy.dart';

class AlbumFoot extends StatelessWidget {
  final VoidCallback? onSelect;
  final VoidCallback? onAdd;
  final VoidCallback? onDownload;

  final Widget? pill;

  // Keeps content above the actions
  static const clearance = 136.0;

  const AlbumFoot({
    super.key,
    required this.onSelect,
    required this.onAdd,
    required this.onDownload,
    this.pill,
  });

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          FootScrim(height: clearance + bottom),
          Padding(
            padding: EdgeInsets.only(left: 44, right: 44, bottom: 18 + bottom),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _Act(label: AlbumCopy.select, onTap: onSelect),
                MakeButton(onTap: onAdd, tooltip: AlbumCopy.addPhotos),
                _Act(label: AlbumCopy.download, onTap: onDownload),
              ],
            ),
          ),
          if (pill != null)
            Positioned(
              right: 16,
              bottom: 96 + bottom,
              child: pill!,
            ),
        ],
      ),
    );
  }
}

class _Act extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;

  const _Act({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
        child: Text(
          label,
          style: Warm.tab.copyWith(
            color: onTap == null ? Warm.inkGhost : Warm.inkFaint,
          ),
        ),
      ),
    );
  }
}
