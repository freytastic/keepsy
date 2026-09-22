import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/e2ee/media_record.dart';

import 'activity_attribution.dart';
import 'activity_derivation.dart';
import 'activity_event.dart';

typedef RecordEvents = Future<void> Function(List<ActivityEvent> events);
typedef ReadSnapshot = Future<Map<String, dynamic>?> Function();
typedef WriteSnapshot = Future<void> Function(Map<String, dynamic> snapshot);
typedef FetchMedia = Future<List<MediaRecord>?> Function(String albumId);
typedef SelfTokenFor = String? Function(String albumId);
typedef CommitObservation = Future<void> Function(
    List<ActivityEvent> events, Map<String, dynamic> snapshot,
    {List<String> settleAlbums});
typedef SettleRotation = Future<void> Function(String albumId);

// Reconstructs changes between authoritative listings because realtime is live-only
class ActivityRecorder {
  final RecordEvents _record;
  final ReadSnapshot _readSnapshot;
  final WriteSnapshot _writeSnapshot;
  final DateTime Function() _now;
  final FetchMedia? _fetchMedia;
  final SelfTokenFor? _selfTokenFor;
  final SettleRotation? _settleRotation;
  final CommitObservation? _commit;

  ActivityRecorder({
    required RecordEvents record,
    required ReadSnapshot readSnapshot,
    required WriteSnapshot writeSnapshot,
    FetchMedia? fetchMedia,
    SelfTokenFor? selfTokenFor,
    SettleRotation? settleRotation,
    CommitObservation? commit,
    DateTime Function()? now,
  })  : _record = record,
        _readSnapshot = readSnapshot,
        _writeSnapshot = writeSnapshot,
        _fetchMedia = fetchMedia,
        _selfTokenFor = selfTokenFor,
        _settleRotation = settleRotation,
        _commit = commit,
        _now = now ?? DateTime.now;

  Future<void> observe(List<AlbumModel> albums) async {
    final stored = await _readSnapshot();
    // null stays null: "never looked" and "looked and saw nothing" are
    // different facts and only the first may be silent
    final previous = stored == null ? null : _decode(stored);
    final current = <String, AlbumSnapshot>{};

    for (final a in albums) {
      // A summary-less album carries zeroes, not truth
      // Keep the prior snapshot to avoid false departures and counter resets
      if (!a.hasSummary) {
        final kept = previous?[a.id];
        if (kept != null) current[a.id] = kept;
        continue;
      }
      current[a.id] = AlbumSnapshot(
        albumId: a.id,
        mediaCount: a.mediaCount,
        mediaGeneration: a.mediaGeneration,
        memberTokens: [for (final m in a.memberPreviews) m.memberToken],
        myRole: a.myRole,
        selfToken: a.memberToken,
        rotationRequired: a.rotationRequired,
        membersComplete: a.memberPreviews.length >= a.activeMemberCount,
        latestActivityAt: a.latestActivityAt,
      );
    }

    final events = await _attribute(
      deriveActivity(previous: previous, current: current, now: _now()),
      current,
    );
    final settle = <String>[
      if (previous != null)
        for (final a in current.values)
          if (!a.rotationRequired &&
              previous[a.albumId]?.rotationRequired == true)
            a.albumId,
    ];
    final snapshot = _encode(current);
    final commit = _commit;
    if (commit != null) {
      // One transaction: a crash in between would re-derive the same
      // transition under a new id, or lose a finished rotation for good
      await commit(events, snapshot, settleAlbums: settle);
      return;
    }
    if (events.isNotEmpty) await _record(events);
    final settleRotation = _settleRotation;
    if (settleRotation != null) {
      for (final id in settle) {
        await settleRotation(id);
      }
    }
    await _writeSnapshot(snapshot);
  }

  // Attribute fetched uploads while preserving the bundle on failure
  Future<List<ActivityEvent>> _attribute(
    List<ActivityEvent> events,
    Map<String, AlbumSnapshot> current,
  ) async {
    final fetch = _fetchMedia;
    if (fetch == null) return events;

    final out = <ActivityEvent>[];
    for (final e in events) {
      if (e is! PhotosAdded) {
        out.add(e);
        continue;
      }
      List<MediaRecord>? media;
      try {
        media = await fetch(e.albumId);
      } catch (_) {
        media = null;
      }
      final through = current[e.albumId]?.mediaGeneration ?? 0;
      out.addAll(attributeUploads(
        bundle: e,
        media: media ?? const [],
        afterSeq: through - e.count,
        throughSeq: through,
        selfToken:
            current[e.albumId]?.selfToken ?? _selfTokenFor?.call(e.albumId),
      ));
    }
    return out;
  }

  Map<String, AlbumSnapshot> _decode(Map<String, dynamic>? raw) {
    if (raw == null) return const {};
    final out = <String, AlbumSnapshot>{};
    for (final entry in raw.entries) {
      final v = entry.value;
      if (v is! Map) continue;
      out[entry.key] = AlbumSnapshot(
        albumId: entry.key,
        mediaCount: (v['media_count'] as num?)?.toInt() ?? 0,
        mediaGeneration: (v['media_generation'] as num?)?.toInt() ?? 0,
        memberTokens: [
          for (final t in (v['members'] as List? ?? const [])) t as String,
        ],
        myRole: v['my_role'] as String?,
        selfToken: v['self'] as String?,
        membersComplete: v['partial'] != true,
        rotationRequired: v['rotation_required'] == true,
        latestActivityAt: v['latest_activity_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (v['latest_activity_at'] as num).toInt(),
                isUtc: true),
      );
    }
    return out;
  }

  Map<String, dynamic> _encode(Map<String, AlbumSnapshot> snaps) => {
        for (final s in snaps.values)
          s.albumId: {
            'media_count': s.mediaCount,
            'media_generation': s.mediaGeneration,
            'members': s.memberTokens,
            if (s.myRole != null) 'my_role': s.myRole,
            if (s.selfToken != null) 'self': s.selfToken,
            if (!s.membersComplete) 'partial': true,
            if (s.rotationRequired) 'rotation_required': true,
            if (s.latestActivityAt != null)
              'latest_activity_at': s.latestActivityAt!.millisecondsSinceEpoch,
          },
      };
}
