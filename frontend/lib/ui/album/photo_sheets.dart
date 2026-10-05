import 'package:flutter/material.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/pressable_scale.dart';
import 'package:keepsy/ui/widgets/warm_button.dart';

import 'album_copy.dart';
import 'album_stats.dart';

Future<T?> _paperSheet<T>(BuildContext context, WidgetBuilder builder) =>
    showModalBottomSheet<T>(
      context: context,
      // Keep sheets above the transparent peek route
      useRootNavigator: true,
      backgroundColor: Warm.paper,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: builder,
    );

Future<bool> confirmPhotoDelete(BuildContext context) async =>
    await _paperSheet<bool>(context, (_) => const _DeleteSheet()) ?? false;

Future<void> showPhotoDetails(
  BuildContext context, {
  required MediaRecord record,
  required Widget face,
  required String? name,
  required bool mine,
  DateTime? now,
}) =>
    _paperSheet<void>(
      context,
      (_) => _DetailsSheet(
        record: record,
        face: face,
        name: name,
        mine: mine,
        now: now,
      ),
    );

String formatPhotoDay(DateTime at, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final days = DateTime(today.year, today.month, today.day)
      .difference(DateTime(at.year, at.month, at.day))
      .inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  if (days < 365 && at.year == today.year) {
    return '${at.day} ${months[at.month - 1]}';
  }
  return '${at.day} ${months[at.month - 1]} ${at.year}';
}

class _Grab extends StatelessWidget {
  const _Grab();

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Warm.inkGhost,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}

class _DeleteSheet extends StatelessWidget {
  const _DeleteSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grab(),
            const SizedBox(height: 20),
            Text(AlbumCopy.deleteTitle, style: Warm.cardTitle),
            const SizedBox(height: 6),
            Text(AlbumCopy.deleteBody, style: Warm.note),
            const SizedBox(height: 22),
            WarmButton(
              key: const Key('photo-delete-confirm'),
              label: AlbumCopy.deleteForEveryone,
              onTap: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: 6),
            PressableScale(
              key: const Key('photo-delete-keep'),
              onTap: () => Navigator.of(context).pop(false),
              child: SizedBox(
                height: 46,
                child: Center(
                  child: Text(AlbumCopy.deleteCancel,
                      style: Warm.acBtnQuiet.copyWith(fontSize: 15)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailsSheet extends StatelessWidget {
  final MediaRecord record;
  final Widget face;
  final String? name;
  final bool mine;
  final DateTime? now;

  const _DetailsSheet({
    required this.record,
    required this.face,
    required this.name,
    required this.mine,
    this.now,
  });

  static String formatOf(MediaRecord record) {
    final mime = record.mimeType;
    if (mime == null || !mime.contains('/')) {
      return record.mediaType == 'video' ? 'Video' : 'Photo';
    }
    final sub = mime.split('/').last.toUpperCase();
    return sub == 'JPG' ? 'JPEG' : sub;
  }

  @override
  Widget build(BuildContext context) {
    final day = formatPhotoDay(record.createdAt, now: now);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: ListView(
          key: const Key('photo-details'),
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
          children: [
            const _Grab(),
            const SizedBox(height: 18),
            Row(
              children: [
                face,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(AlbumCopy.sharedBy(name, mine: mine),
                          style: Warm.factTitle),
                      Text(day, style: Warm.meta),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Container(
              decoration: BoxDecoration(
                color: Warm.wellEmpty.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(16),
              ),
              child: IntrinsicHeight(
                child: Row(
                  children: [
                    Expanded(
                      child: _Fact(
                        label: AlbumCopy.factSize,
                        value: AlbumStats.formatBytes(
                            AlbumStats.storedBytes(record)),
                      ),
                    ),
                    const VerticalDivider(width: 1, color: Warm.inkGhost),
                    Expanded(
                      child: _Fact(
                          label: AlbumCopy.factFormat, value: formatOf(record)),
                    ),
                    const VerticalDivider(width: 1, color: Warm.inkGhost),
                    Expanded(
                      child: _Fact(label: AlbumCopy.factAdded, value: day),
                    ),
                  ],
                ),
              ),
            ),
            if (record.mediaType == 'photo') ...[
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Icon(Icons.lock_outline_rounded,
                        size: 14, color: Warm.inkFaint),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(AlbumCopy.encryptedOn(name, mine: mine),
                        style: Warm.note),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 22),
            const _Section(
                title: AlbumCopy.hearts, body: AlbumCopy.heartsLater),
            const SizedBox(height: 18),
            const _Section(
                title: AlbumCopy.comments, body: AlbumCopy.commentsLater),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              decoration: BoxDecoration(
                color: Warm.fieldFill,
                borderRadius: BorderRadius.circular(21),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(AlbumCopy.sayPlaceholder,
                        style: Warm.meta.copyWith(color: Warm.inkFaint)),
                  ),
                  const _Chip(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;

  const _Fact({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: Warm.sectionLabel),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Warm.rowTitle.copyWith(
                fontSize: 13.5,
                fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String body;

  const _Section({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(title, style: Warm.rowTitle.copyWith(fontSize: 14)),
            const SizedBox(width: 8),
            const _Chip(),
          ],
        ),
        const SizedBox(height: 6),
        Text(body, style: Warm.note),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Warm.inkGhost,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        AlbumCopy.betaV2,
        style: Warm.sectionLabel.copyWith(letterSpacing: 0.3),
      ),
    );
  }
}
