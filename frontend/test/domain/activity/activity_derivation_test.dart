import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/domain/activity/activity_event.dart';
import 'package:keepsy/domain/activity/activity_derivation.dart';

void main() {
  final now = DateTime.utc(2026, 9, 21, 12);

  AlbumSnapshot snap(
    String id, {
    int media = 0,
    int generation = 1,
    List<String> members = const ['me'],
    String role = 'member',
    bool rotationRequired = false,
    String? self,
    DateTime? last,
  }) =>
      AlbumSnapshot(
        albumId: id,
        selfToken: self,
        mediaCount: media,
        mediaGeneration: generation,
        memberTokens: members,
        myRole: role,
        rotationRequired: rotationRequired,
        latestActivityAt: last,
      );

  Map<String, AlbumSnapshot> byId(List<AlbumSnapshot> xs) => {
        for (final x in xs) x.albumId: x,
      };

  List<ActivityEvent> derive(
    List<AlbumSnapshot>? before,
    List<AlbumSnapshot> after,
  ) =>
      deriveActivity(
        previous: before == null ? null : byId(before),
        current: byId(after),
        now: now,
      );

  group('the first run on a phone that already has history', () {
    test('emits nothing and merely seeds the baseline', () {
      final events = derive(null, [snap('a', media: 40), snap('b', media: 12)]);
      expect(events, isEmpty);
    });

    // An empty shelf is a valid baseline and must detect the first invitation
    test('an empty shelf is a real baseline, not the absence of one', () {
      final events = derive([], [snap('b')]);

      expect(events, hasLength(1));
      expect(events.single, isA<InvitedToAlbum>());
    });
  });

  group('photos', () {
    // media_generation only moves on a confirmed upload, so it counts
    // additions; mediaCount is net of deletions
    test('the generation difference becomes one row', () {
      final events = derive([snap('a', media: 3, generation: 3)],
          [snap('a', media: 8, generation: 8)]);

      expect(events, hasLength(1));
      final e = events.single as PhotosAdded;
      expect(e.albumId, 'a');
      expect(e.count, 5);
      expect(e.lane, ActivityLane.albums);
    });

    test('a deletion alone says nothing', () {
      expect(
          derive([snap('a', media: 8, generation: 8)],
              [snap('a', media: 3, generation: 8)]),
          isEmpty);
    });

    // One photo deleted and one added while offline left the count flat, so
    // the upload vanished from Activity
    test('an addition offset by a deletion is still reported', () {
      final events = derive([snap('a', media: 8, generation: 8)],
          [snap('a', media: 8, generation: 9)]);
      expect((events.single as PhotosAdded).count, 1);
    });

    test('photos keep the server time of the upload', () {
      final upload = DateTime.utc(2026, 9, 1, 10);
      final events = derive(
          [snap('a', generation: 1)], [snap('a', generation: 2, last: upload)]);
      expect(events.single.at, upload);
    });

    test('an unchanged album says nothing', () {
      expect(derive([snap('a', media: 8)], [snap('a', media: 8)]), isEmpty);
    });
  });

  group('membership', () {
    test('a new member token becomes a joined row', () {
      final events = derive(
        [
          snap('a', members: ['me', 'sam'])
        ],
        [
          snap('a', members: ['me', 'sam', 'noor'])
        ],
      );

      final e = events.single as MemberJoined;
      expect(e.memberToken, 'noor');
      expect(e.lane, ActivityLane.security);
      expect(e.needsDecision, isFalse);
    });

    // Revocation commits before rotation, which may remain owed
    test('a departure carries whether the rotation is still owed', () {
      final pending = derive(
        [
          snap('a', members: ['me', 'juno'])
        ],
        [
          snap('a', members: ['me'], rotationRequired: true)
        ],
      ).single as MemberLeft;
      expect(pending.rotationPending, isTrue);

      final done = derive(
        [
          snap('a', members: ['me', 'juno'])
        ],
        [
          snap('a', members: ['me'])
        ],
      ).single as MemberLeft;
      expect(done.rotationPending, isFalse);
    });

    test('a vanished member token becomes a left row', () {
      final events = derive(
        [
          snap('a', members: ['me', 'sam', 'juno'])
        ],
        [
          snap('a', members: ['me', 'sam'])
        ],
      );

      final e = events.single as MemberLeft;
      expect(e.memberToken, 'juno');
      expect(e.lane, ActivityLane.security);
    });
  });

  group('albums arriving and leaving', () {
    test('an album you did not create means you were invited', () {
      final events = derive([snap('a')], [snap('a'), snap('b')]);

      final e = events.single as InvitedToAlbum;
      expect(e.albumId, 'b');
      expect(e.lane, ActivityLane.security);
      expect(e.needsDecision, isTrue);
    });

    test('an album you created yourself is not an invitation', () {
      final events = derive(
          [snap('a')], [snap('a'), snap('b', role: 'admin', generation: 0)]);
      expect(events, isEmpty);
    });

    // A new owned album can already contain member uploads at first listing
    test('an album you own seen for the first time reports what others did',
        () {
      final events = derive([], [
        snap('b',
            role: 'admin',
            media: 3,
            generation: 3,
            members: ['me', 'noor'],
            self: 'me'),
      ]);

      expect(events.whereType<InvitedToAlbum>(), isEmpty);
      expect((events.whereType<PhotosAdded>().single).count, 3);
      expect(events.whereType<MemberJoined>().single.memberToken, 'noor');
    });

    // Without our own token we cannot tell ourselves apart from the others,
    // and "you joined your own album" is worse than saying nothing
    test('an owned album with no known self token reports no joins', () {
      final events = derive([], [
        snap('b',
            role: 'admin', media: 2, generation: 2, members: ['me', 'noor']),
      ]);

      expect(events.whereType<MemberJoined>(), isEmpty);
      expect(events.whereType<PhotosAdded>().single.count, 2);
    });

    test('an album you were invited to stays a single invitation', () {
      final events = derive([], [
        snap('b', media: 30, members: ['own', 'me', 'noor'], self: 'me'),
      ]);

      expect(events.single, isA<InvitedToAlbum>());
    });

    test('an album that disappeared means you were removed', () {
      final events = derive([snap('a'), snap('b')], [snap('a')]);

      final e = events.single as RemovedFromAlbum;
      expect(e.albumId, 'b');
      expect(e.lane, ActivityLane.security);
      expect(e.needsDecision, isTrue);
    });
  });

  group('running twice over the same change', () {
    // Stable ids prevent repeat rows when the same transition is derived again
    test('gives the same ids both times', () {
      final before = [
        snap('a', media: 3, members: ['me'])
      ];
      final after = [
        snap('a', media: 8, generation: 2, members: ['me', 'noor'])
      ];

      final first = derive(before, after).map((e) => e.id).toList();
      final second = derive(before, after).map((e) => e.id).toList();

      expect(first, second);
      expect(first.toSet(), hasLength(first.length),
          reason: 'ids must be unique');
    });
  });

  // The album's last upload says nothing about when someone joined, so a
  // join today would have been filed under last month
  group('membership is dated when this phone noticed it', () {
    final old = DateTime.utc(2026, 8, 1);

    test('joins and departures', () {
      final events = derive(
        [
          snap('a', members: ['me', 'juno'], last: old)
        ],
        [
          snap('a', members: ['me', 'noor'], last: old)
        ],
      );
      expect(events.map((e) => e.at).toSet(), {now});
    });

    test('invitations and removals', () {
      final events = derive(
        [snap('gone', last: old)],
        [snap('new', last: old)],
      );
      expect(events.map((e) => e.at).toSet(), {now});
    });
  });

  // Member tokens are reused on re-invite, so an id of album:token made a
  // second departure or rejoin look like a duplicate of the first and it was
  // silently dropped
  group('a second time is a second row', () {
    test('leaving again after rejoining gets its own id', () {
      final first = deriveActivity(
        previous: byId([
          snap('a', members: ['me', 'juno'])
        ]),
        current: byId([
          snap('a', members: ['me'])
        ]),
        now: DateTime.utc(2026, 9, 1),
      ).single;
      final second = deriveActivity(
        previous: byId([
          snap('a', members: ['me', 'juno'])
        ]),
        current: byId([
          snap('a', members: ['me'])
        ]),
        now: DateTime.utc(2026, 9, 20),
      ).single;

      expect(first.id, isNot(second.id));
    });

    test('being invited back gets its own id', () {
      final first = deriveActivity(
              previous: byId([]),
              current: byId([snap('b')]),
              now: DateTime.utc(2026, 9, 1))
          .single;
      final again = deriveActivity(
              previous: byId([]),
              current: byId([snap('b')]),
              now: DateTime.utc(2026, 9, 20))
          .single;

      expect(first.id, isNot(again.id));
    });
  });
}
