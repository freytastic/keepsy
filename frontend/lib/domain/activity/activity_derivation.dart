import 'activity_event.dart';

// What the last authoritative shelf summary said about one album
class AlbumSnapshot {
  final String albumId;
  final int mediaCount;
  final int mediaGeneration;
  final List<String> memberTokens;
  final String? myRole;
  final String? selfToken;
  final bool rotationRequired;
  // Partial member lists cannot prove joins or departures
  final bool membersComplete;
  final DateTime? latestActivityAt;

  const AlbumSnapshot({
    required this.albumId,
    required this.mediaCount,
    required this.mediaGeneration,
    required this.memberTokens,
    required this.myRole,
    required this.latestActivityAt,
    this.selfToken,
    this.rotationRequired = false,
    this.membersComplete = true,
  });
}

// Reconstructs changes without network, storage, or hidden clocks
List<ActivityEvent> deriveActivity({
  // null means never observed; an empty map is a real empty baseline
  // Conflating them swallows the first invitation
  required Map<String, AlbumSnapshot>? previous,
  required Map<String, AlbumSnapshot> current,
  required DateTime now,
}) {
  // Emitting a row per historical photo would bury the user on first launch,
  // so the first pass only learns the baseline
  if (previous == null) return const [];

  final out = <ActivityEvent>[];
  // Reused member tokens need observation time to distinguish later rejoins
  // The recorder commits rows and snapshot together to prevent duplicates
  final seen = now.millisecondsSinceEpoch;

  for (final album in current.values) {
    var before = previous[album.albumId];
    // Only photos carry server time; membership is dated when observed
    final photoAt = album.latestActivityAt ?? now;

    if (before == null) {
      // History from before your invitation is not news to you
      if (album.myRole != 'admin') {
        out.add(InvitedToAlbum(
          id: 'invited:${album.albumId}:$seen',
          albumId: album.albumId,
          at: now,
        ));
        continue;
      }
      // Model a new owned album from its empty, owner-only baseline
      final self = album.selfToken;
      before = AlbumSnapshot(
        albumId: album.albumId,
        mediaCount: 0,
        mediaGeneration: 0,
        memberTokens: self == null || !album.membersComplete
            ? album.memberTokens
            : [self],
        myRole: album.myRole,
        latestActivityAt: null,
      );
    }

    // media_generation counts uploads while mediaCount is net of deletions
    final added = album.mediaGeneration - before.mediaGeneration;
    if (added > 0) {
      out.add(PhotosAdded(
        id: 'added:${album.albumId}:${album.mediaGeneration}',
        albumId: album.albumId,
        at: photoAt,
        count: added,
      ));
    }

    // A member sliding into a capped list is not evidence of a join
    final rosterKnown = before.membersComplete && album.membersComplete;
    final was = rosterKnown ? before.memberTokens.toSet() : const <String>{};
    final is_ = rosterKnown ? album.memberTokens.toSet() : const <String>{};
    for (final token in is_.difference(was)) {
      out.add(MemberJoined(
        id: 'joined:${album.albumId}:$token:$seen',
        albumId: album.albumId,
        at: now,
        memberToken: token,
      ));
    }
    for (final token in was.difference(is_)) {
      out.add(MemberLeft(
        id: 'left:${album.albumId}:$token:$seen',
        albumId: album.albumId,
        at: now,
        memberToken: token,
        rotationPending: album.rotationRequired,
      ));
    }
  }

  for (final gone in previous.keys.where((id) => !current.containsKey(id))) {
    out.add(RemovedFromAlbum(
      id: 'removed:$gone:$seen',
      albumId: gone,
      at: now,
    ));
  }

  return out;
}
