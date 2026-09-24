import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/domain/activity/activity_event.dart';
import 'package:keepsy/ui/activity/activity_copy.dart';

void main() {
  final at = DateTime.utc(2026, 9, 20, 10);

  String name(String token) =>
      {'noor': 'Noor', 'juno': 'Juno'}[token] ?? 'Someone';
  String title(String id) => {'a': 'Birthday'}[id] ?? 'an album';

  final names = ActivityNames(memberName: (_, t) => name(t), albumTitle: title);

  group('cards, for the things waiting on a decision', () {
    test('a safety number says what it might mean, without jargon', () {
      final copy = cardCopyFor(
        SafetyNumberChanged(id: 'x', albumId: 'a', at: at, peerToken: 'noor'),
        names,
      );

      expect(copy.title, "Noor's safety number changed");
      expect(copy.where, 'Birthday');
      // In this build a new phone cannot keep the same membership (the
      // account gate refuses it), so "probably a new phone" was false comfort
      expect(copy.body.toLowerCase(), isNot(contains('new phone')));
      expect(copy.body.toLowerCase(), isNot(contains('probably')));
      expect(copy.body, contains("shouldn't happen"));
      expect(copy.body, contains('pretending'));
      expect(copy.body.toLowerCase(), isNot(contains('fingerprint')));
      expect(copy.body.toLowerCase(), isNot(contains('identity key')));
      expect(copy.go, 'Compare');
    });

    // The key and membership arrive before the shelf lists the album
    test('an added album offers to open it, not to join it', () {
      final copy = cardCopyFor(
        InvitedToAlbum(id: 'x', albumId: 'a', at: at),
        names,
      );

      expect(copy.title, contains('Birthday'));
      expect(copy.go, 'Open');
      expect(copy.go, isNot('Join'));
      expect(copy.body, contains('still arriving'));
    });

    test('a removal says what actually happened, and only acknowledges', () {
      final copy = cardCopyFor(
        RemovedFromAlbum(id: 'x', albumId: 'a', at: at),
        names,
      );

      expect(copy.title, contains('no longer have access'));
      // Cleanup can lag while offline
      expect(copy.body, contains('being removed from this phone'));
      expect(copy.body, isNot(contains('rotated')));
      expect(copy.body, isNot(contains('stays')));
      expect(copy.go, 'Okay');
      expect(copy.quiet, isNull, reason: 'the copy is already gone');
    });
  });

  group('rows, for the things that merely happened', () {
    test('photos name the uploader when one is known', () {
      final line = lineFor(
        PhotosAdded(
            id: 'x', albumId: 'a', at: at, count: 5, uploaderToken: 'noor'),
        names,
      );

      expect(line.lead, 'Noor');
      expect(line.rest, ' added 5 photos');
      expect(line.where, 'Birthday');
    });

    // The shelf summary counts without attributing, so the row has to read
    // properly with nobody named rather than inventing one
    test('photos read without a name when nobody is attributed', () {
      final line = lineFor(
        PhotosAdded(id: 'x', albumId: 'a', at: at, count: 5),
        names,
      );

      expect(line.lead, '5 photos');
      expect(line.rest, ' were added');
    });

    test('one photo is not pluralised', () {
      final line = lineFor(
        PhotosAdded(
            id: 'x', albumId: 'a', at: at, count: 1, uploaderToken: 'noor'),
        names,
      );
      expect(line.rest, ' added 1 photo');
    });

    test('a completed rotation says what it bought you', () {
      final line = lineFor(
        MemberLeft(
            id: 'x',
            albumId: 'a',
            at: at,
            memberToken: 'juno',
            rotationPending: false),
        names,
      );

      expect(line.lead, 'Juno');
      expect(line.rest, ' left');
      expect(line.aside, contains("can't see anything added"));
      expect(line.aside, isNot(contains('still locking')));
      expect(line.warn, isFalse);
    });

    test('an owed rotation says so instead of claiming it happened', () {
      final line = lineFor(
        MemberLeft(
            id: 'x',
            albumId: 'a',
            at: at,
            memberToken: 'juno',
            rotationPending: true),
        names,
      );

      expect(line.aside, isNot(contains("can't see")));
      expect(line.aside, contains('still locking'));
      expect(line.warn, isTrue);
    });

    test('a compared safety number says it matched and stops warning', () {
      final line = lineFor(
        SafetyNumberChanged(
            id: 't', albumId: 'a', at: at, peerToken: 'noor', verified: true),
        names,
      );
      expect(line.aside, contains('matched'));
      expect(line.warn, isFalse);
    });

    test('an uncompared safety number keeps warning after dismissal', () {
      final line = lineFor(
        SafetyNumberChanged(id: 'x', albumId: 'a', at: at, peerToken: 'noor'),
        names,
      );

      expect(line.aside, contains("haven't compared"));
      expect(line.warn, isTrue);
    });
  });

  group('headings', () {
    test('security counts what needs review and names the alarm', () {
      final say =
          sayForSecurity(needs: 2, happened: 4, changedSafetyNumber: 'Noor');
      expect(say.title, '2 security updates to review.');
      expect(say.sub, "One is Noor's changed safety number.");
    });

    test('security without an alarm points at access changes', () {
      final say = sayForSecurity(needs: 1, happened: 0);
      expect(say.title, '1 security update to review.');
      expect(say.sub, contains('access'));
    });

    test('security says so plainly when nothing is waiting', () {
      expect(sayForSecurity(needs: 0, happened: 9).title, "You're up to date.");
      expect(sayForSecurity(needs: 0, happened: 9).sub,
          'Nothing needs you right now.');
    });

    test('security has an empty state that promises what will appear', () {
      final say = sayForSecurity(needs: 0, happened: 0);
      expect(say.title, 'No security activity yet.');
      expect(say.sub, contains('will appear here'));
    });

    test('albums count photos and the albums they landed in', () {
      final say = sayForAlbums(photos: 40, albums: 3);
      expect(say.title, '40 photos arrived.');
      expect(say.sub, startsWith('Across 3 albums,'));
      expect(sayForAlbums(photos: 1, albums: 1).title, '1 photo arrived.');
      expect(sayForAlbums(photos: 1, albums: 1).sub,
          startsWith('Across 1 album,'));
    });

    test('albums have a quiet empty state', () {
      final say = sayForAlbums(photos: 0, albums: 0);
      expect(say.title, 'Nothing new.');
      expect(say.sub, 'New photos will gather here.');
    });
  });

  group('day labels follow the phone\'s own calendar', () {
    final now = DateTime(2026, 9, 22, 9);

    test('just after local midnight is today', () {
      expect(dayLabel(DateTime(2026, 9, 22, 1, 30).toUtc(), now: now), 'Today');
    });

    test('late last night is yesterday', () {
      expect(dayLabel(DateTime(2026, 9, 21, 23, 30).toUtc(), now: now),
          'Yesterday');
    });

    test('older spans read as spans', () {
      expect(dayLabel(DateTime(2026, 9, 18).toUtc(), now: now),
          'Earlier this week');
      expect(dayLabel(DateTime(2026, 9, 2).toUtc(), now: now),
          'Earlier this month');
      expect(dayLabel(DateTime(2026, 6, 1).toUtc(), now: now), 'Older');
    });
  });
}
