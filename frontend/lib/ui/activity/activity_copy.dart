import 'package:keepsy/domain/activity/activity_event.dart';

// Names are sealed per album, so a token alone cannot resolve one
class ActivityNames {
  final String Function(String albumId, String memberToken) memberName;
  final String Function(String albumId) albumTitle;
  const ActivityNames({required this.memberName, required this.albumTitle});
}

class CardCopy {
  final String title;
  final String where;
  final String body;
  final String go;
  final String? quiet;
  const CardCopy({
    required this.title,
    required this.where,
    required this.body,
    required this.go,
    this.quiet,
  });
}

class LineCopy {
  final String lead;
  final String rest;
  final String where;
  final String? aside;
  final bool warn;
  const LineCopy({
    required this.lead,
    required this.rest,
    required this.where,
    this.aside,
    this.warn = false,
  });
}

class Say {
  final String title;
  final String sub;
  const Say(this.title, this.sub);
}

CardCopy cardCopyFor(ActivityEvent e, ActivityNames names) {
  final where = names.albumTitle(e.albumId);
  return switch (e) {
    SafetyNumberChanged() => CardCopy(
        title:
            "${names.memberName(e.albumId, e.peerToken)}'s safety number changed",
        where: where,
        // Account binding rules out a same-membership phone change, so this is
        // never "probably a new phone"
        body: "This shouldn't happen. It can mean someone is pretending to be "
            '${names.memberName(e.albumId, e.peerToken)}. Compare your numbers '
            'before you trust new photos from them.',
        go: 'Compare',
        quiet: 'Not now',
      ),
    // The album and key are already present when this event is derived
    InvitedToAlbum() => CardCopy(
        title: 'You were added to $where',
        where: 'Now on your shelf',
        body: 'The key reached your phone, so the album is yours to open. '
            'The photographs are still arriving.',
        go: 'Open',
        quiet: 'Later',
      ),
    // Covers removal and deletion while offline cleanup may still be queued
    RemovedFromAlbum() => CardCopy(
        title: 'You no longer have access to $where',
        where: 'No longer on your shelf',
        body: 'You were removed, or the album was deleted. Its photos and keys '
            'are being removed from this phone.',
        go: 'Okay',
      ),
    _ => CardCopy(
        title: 'Something changed',
        where: where,
        body: 'Open the album to see.',
        go: 'Okay',
        quiet: 'Not now',
      ),
  };
}

LineCopy lineFor(ActivityEvent e, ActivityNames names) {
  final where = names.albumTitle(e.albumId);
  return switch (e) {
    PhotosAdded() => _photos(e, names, where),
    MemberJoined() => LineCopy(
        lead: names.memberName(e.albumId, e.memberToken),
        rest: ' joined',
        where: where,
      ),
    MemberLeft() => LineCopy(
        lead: names.memberName(e.albumId, e.memberToken),
        rest: ' left',
        where: where,
        // Removal commits before rotation, which can still fail
        aside: e.rotationPending
            ? "The album's new key is not finished yet, so "
                '${names.memberName(e.albumId, e.memberToken)} may still be '
                'able to read what gets added until it is.'
            : "The album's key was rotated. "
                '${names.memberName(e.albumId, e.memberToken)} '
                "can't read anything added from here on.",
        warn: e.rotationPending,
      ),
    SafetyNumberChanged() => LineCopy(
        lead: names.memberName(e.albumId, e.peerToken),
        rest: "'s safety number changed",
        where: where,
        aside: e.verified
            ? 'You compared it and it matched.'
            : "You haven't compared it yet.",
        warn: !e.verified,
      ),
    InvitedToAlbum() => LineCopy(
        lead: 'You', rest: ' were added to $where', where: 'On your shelf'),
    RemovedFromAlbum() => LineCopy(
        lead: 'You',
        rest: ' no longer have access to $where',
        where: 'No longer on your shelf',
      ),
  };
}

// The shelf summary counts without attributing, so the row has to read
// properly with nobody named rather than inventing one
LineCopy _photos(PhotosAdded e, ActivityNames names, String where) {
  final plural = e.count == 1 ? 'photo' : 'photos';
  final who = e.uploaderToken;
  if (who == null) {
    return LineCopy(
      lead: '${e.count} $plural',
      rest: e.count == 1 ? ' was added' : ' were added',
      where: where,
    );
  }
  return LineCopy(
    lead: names.memberName(e.albumId, who),
    rest: ' added ${e.count} $plural',
    where: where,
  );
}

Say sayForSecurity({
  required int needs,
  required int happened,
  String? changedSafetyNumber,
}) {
  if (needs == 0 && happened == 0) {
    return const Say('No security activity yet.',
        'Safety and access updates will appear here.');
  }
  if (needs == 0) {
    final one = happened == 1;
    return Say("You're up to date.",
        '$happened recent security update${one ? ' is' : 's are'} in your history.');
  }
  return Say(
    '$needs security update${needs == 1 ? '' : 's'} to review.',
    changedSafetyNumber != null
        ? "One is $changedSafetyNumber's changed safety number."
        : 'Review the latest access changes to your albums.',
  );
}

Say sayForAlbums({required int photos, required int albums}) {
  if (photos == 0) {
    return const Say('Nothing new.', 'New photos will gather here.');
  }
  return Say(
    '$photos photo${photos == 1 ? '' : 's'} arrived.',
    'Across $albums album${albums == 1 ? '' : 's'}, from the people you share '
        'them with.',
  );
}

// Group stored UTC timestamps by the phone's local calendar date
String dayLabel(DateTime at, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final local = at.toLocal();
  final days = DateTime(today.year, today.month, today.day)
      .difference(DateTime(local.year, local.month, local.day))
      .inDays;
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 7) return 'Earlier this week';
  if (days < 30) return 'Earlier this month';
  return 'Older';
}
