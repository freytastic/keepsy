import 'package:flutter/material.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/ui/album/member_avatars.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/member_face.dart';

import 'activity_copy.dart';

typedef ActivityThumb = Widget Function(MediaRecord record);

class ActivityRow extends StatelessWidget {
  final LineCopy line;
  final Widget face;
  final VoidCallback? onTap;
  final List<MediaRecord> previews;
  final int more;
  final ActivityThumb? thumb;

  const ActivityRow({
    super.key,
    required this.line,
    required this.face,
    this.onTap,
    this.previews = const [],
    this.more = 0,
    this.thumb,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: '${line.lead}${line.rest}, ${line.where}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // Read state lives in tab and shelf indicators, not row opacity
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              face,
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: line.lead, style: Warm.acLead),
                            TextSpan(text: line.rest, style: Warm.acLine),
                          ],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(line.where, style: Warm.acWhere),
                      if (line.aside != null) _Aside(line.aside!, line.warn),
                    ],
                  ),
                ),
              ),
              if (previews.isNotEmpty) ...[
                const SizedBox(width: 12),
                _Thumbs(previews: previews, more: more, thumb: thumb),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Aside extends StatelessWidget {
  final String text;
  final bool warn;
  const _Aside(this.text, this.warn);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 7),
      padding: const EdgeInsets.only(left: 11),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: warn ? Warm.warn : Warm.inkGhost, width: 1.5),
        ),
      ),
      child: Text(
        text,
        style: warn ? Warm.acAside.copyWith(color: Warm.warn) : Warm.acAside,
      ),
    );
  }
}

class _Thumbs extends StatelessWidget {
  final List<MediaRecord> previews;
  final int more;
  final ActivityThumb? thumb;
  const _Thumbs({required this.previews, required this.more, this.thumb});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < previews.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                width: 30,
                height: 30,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: Warm.wellEmpty),
                    if (thumb != null) thumb!(previews[i]),
                    if (i == previews.length - 1 && more > 0)
                      ColoredBox(
                        color: const Color(0x85181410),
                        child: Center(
                          child: Text('+$more', style: Warm.acMore),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// Unresolved sealed names appear only as their stable album colour
class ActivityFace extends StatelessWidget {
  final String? albumId;
  final String? name;
  final String? token;
  final bool alarm;
  const ActivityFace(
      {super.key, this.albumId, this.name, this.token, this.alarm = false});

  @override
  Widget build(BuildContext context) {
    final initial = (name == null || name!.isEmpty)
        ? ''
        : name!.characters.first.toUpperCase();
    final t = token;
    final photo = memberPhoto(context, t == null ? null : albumId, t ?? '');
    return SizedBox(
      width: 32,
      height: 32,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          FaceCircle(
            size: 32,
            color: t == null
                ? const Color(0x0F1C1917)
                : MemberAvatars.hueFor(t).withValues(alpha: 0.95),
            // A changed key may be an impostor, so its card never shows a face
            photo: alarm ? null : photo,
            child: Text(initial, style: Warm.acFace),
          ),
          if (alarm)
            Positioned(
              right: -3,
              bottom: -3,
              child: Container(
                width: 18,
                height: 18,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Warm.warn,
                  border: Border.all(color: const Color(0xFFEFEBE3), width: 2),
                ),
                child: const Icon(Icons.fingerprint_rounded,
                    size: 11, color: Warm.paper),
              ),
            ),
        ],
      ),
    );
  }
}
