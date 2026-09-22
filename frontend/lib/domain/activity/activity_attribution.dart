import 'package:keepsy/e2ee/media_record.dart';

import 'activity_event.dart';

const int kActivityPreviews = 3;

// Splits sequenced uploads by uploader, or keeps the unnamed bundle
List<PhotosAdded> attributeUploads({
  required PhotosAdded bundle,
  required List<MediaRecord> media,
  required String? selfToken,
  required int afterSeq,
  required int throughSeq,
}) {
  // Bounds stop deleted new uploads shifting credit to older survivors
  final arrived = [
    for (final m in media)
      if (m.albumSeq case final seq? when seq > afterSeq && seq <= throughSeq)
        m,
  ];
  // Missing sequence data must not produce a guessed name
  if (arrived.isEmpty) return [bundle];

  final counts = <String, int>{};
  final latest = <String, DateTime>{};
  final previews = <String, List<MediaRecord>>{};
  for (final m in arrived) {
    if (m.uploaderToken == selfToken) continue;
    final who = m.uploaderToken;
    counts[who] = (counts[who] ?? 0) + 1;
    // Keep one uploader's old photos out of another uploader's day group
    final was = latest[who];
    if (was == null || m.createdAt.isAfter(was)) latest[who] = m.createdAt;
    final shown = previews.putIfAbsent(who, () => []);
    if (shown.length < kActivityPreviews) shown.add(m);
  }

  final byVolume = counts.entries.toList()
    ..sort((a, b) {
      final n = b.value.compareTo(a.value);
      return n != 0 ? n : a.key.compareTo(b.key);
    });

  // Deleted arrivals still count, but can no longer be attributed
  final missing = bundle.count - arrived.length;

  return [
    for (final e in byVolume)
      PhotosAdded(
        id: '${bundle.id}:${e.key}',
        albumId: bundle.albumId,
        at: latest[e.key] ?? bundle.at,
        count: e.value,
        uploaderToken: e.key,
        previews: previews[e.key] ?? const [],
      ),
    if (missing > 0)
      PhotosAdded(
        id: '${bundle.id}:unknown',
        albumId: bundle.albumId,
        at: bundle.at,
        count: missing,
      ),
  ];
}
