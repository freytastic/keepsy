import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:keepsy/data/storage/activity_store.dart';
import 'package:keepsy/domain/activity/activity_event.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/ui/activity/activity_copy.dart';
import 'package:keepsy/ui/activity/activity_screen.dart';

// Widget tests use an in-memory feed because sqflite needs real file I/O
class FakeFeed implements ActivityFeed {
  final List<StoredActivity> rows = [];

  final List<String> dismissed = [];

  void add(ActivityEvent e, {bool seen = false, bool dismissed = false}) =>
      rows.add(StoredActivity(event: e, seen: seen, dismissed: dismissed));

  @override
  Future<void> resolveVerified(SafetyNumberChanged e) async {
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].event.id == e.id) {
        rows[i] =
            StoredActivity(event: e.asVerified(), seen: true, dismissed: true);
      }
    }
  }

  @override
  Future<void> dismiss(String id) async {
    dismissed.add(id);
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].event.id == id) {
        rows[i] = StoredActivity(
            event: rows[i].event, seen: rows[i].seen, dismissed: true);
      }
    }
  }

  @override
  Future<List<StoredActivity>> read({ActivityLane? lane}) async {
    final xs =
        lane == null ? rows : rows.where((r) => r.event.lane == lane).toList();
    return [...xs]..sort((a, b) => b.event.at.compareTo(a.event.at));
  }

  @override
  Future<void> markSeen(Iterable<String> ids) async {
    for (var i = 0; i < rows.length; i++) {
      if (ids.contains(rows[i].event.id)) {
        rows[i] = StoredActivity(
            event: rows[i].event, seen: true, dismissed: rows[i].dismissed);
      }
    }
  }

  @override
  Future<int> unseenCount(ActivityLane lane) async =>
      rows.where((r) => r.event.lane == lane && !r.seen).length;
}

void main() {
  late FakeFeed store;
  final at = DateTime.now().subtract(const Duration(hours: 2));

  final names = ActivityNames(
    memberName: (_, t) => {'noor': 'Noor', 'juno': 'Juno'}[t] ?? 'Someone',
    albumTitle: (id) => 'Birthday',
  );

  setUp(() => store = FakeFeed());

  final unreadSeen = <bool>[];

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ActivityScreen(
        store: store,
        names: names,
        onUnreadChanged: unreadSeen.add,
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('opening compares first, then reads', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ActivityScreen(
        store: store,
        names: names,
        refresh: () async => store.add(PhotosAdded(
            id: 'p', albumId: 'a', at: at, count: 2, uploaderToken: 'noor')),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Noor added 2 photos', findRichText: true),
        findsOneWidget);
  });

  testWidgets('a safety number is raised as a card, not buried in the stream',
      (tester) async {
    store.add(
        SafetyNumberChanged(id: 't', albumId: 'a', at: at, peerToken: 'noor'));
    await pump(tester);

    expect(find.text("Noor's safety number changed"), findsOneWidget);
    expect(find.text('Compare'), findsOneWidget);
    expect(find.text('1 security update to review.'), findsOneWidget);
    expect(find.text("One is Noor's changed safety number."), findsOneWidget);
    expect(find.text('1 to review'), findsOneWidget);
  });

  testWidgets('a membership change belongs to Security, not Albums',
      (tester) async {
    store.add(MemberJoined(id: 'j', albumId: 'a', at: at, memberToken: 'juno'));
    await pump(tester);

    expect(find.textContaining('Juno', findRichText: true), findsOneWidget);

    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing has been added to your albums yet.'),
        findsOneWidget);
  });

  testWidgets('an upload belongs to Albums, not Security', (tester) async {
    store.add(PhotosAdded(
        id: 'p', albumId: 'a', at: at, count: 5, uploaderToken: 'noor'));
    await pump(tester);

    expect(find.text('Nothing has changed about who can read your albums.'),
        findsOneWidget);

    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();

    expect(find.textContaining('added 5 photos', findRichText: true),
        findsOneWidget);
  });

  testWidgets('a tab flags only its own unseen rows', (tester) async {
    store.add(PhotosAdded(id: 'p1', albumId: 'a', at: at, count: 5));
    store.add(PhotosAdded(id: 'p2', albumId: 'a', at: at, count: 2));
    store.add(MemberJoined(id: 'j', albumId: 'a', at: at, memberToken: 'juno'));
    await pump(tester);

    expect(find.byKey(const ValueKey('attention-security')), findsNothing);
    expect(find.byKey(const ValueKey('attention-albums')), findsOneWidget);
    expect(find.text('7 photos'), findsOneWidget);
  });

  testWidgets('the albums heading counts what arrived', (tester) async {
    store.add(PhotosAdded(id: 'p1', albumId: 'a', at: at, count: 5));
    store.add(PhotosAdded(id: 'p2', albumId: 'b', at: at, count: 2));
    await pump(tester);

    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();

    expect(find.text('7 photos arrived.'), findsOneWidget);
    expect(find.textContaining('Across 2 albums'), findsOneWidget);
  });

  testWidgets('an upload row shows its previews and how many more',
      (tester) async {
    final shown = <String>[];
    final rec = MediaRecord(
      id: 'm1',
      albumId: 'a',
      uploaderToken: 'noor',
      wrapNonce: Uint8List(12),
      wrapTagCT: Uint8List(48),
      epochTag: 1,
      blobSize: 10,
      blobSha256: Uint8List(32),
      mediaType: 'photo',
      mimeType: 'image/jpeg',
      createdAt: at,
    );
    store.add(PhotosAdded(
        id: 'p',
        albumId: 'a',
        at: at,
        count: 5,
        uploaderToken: 'noor',
        previews: [rec]));
    await tester.pumpWidget(MaterialApp(
      home: ActivityScreen(
        store: store,
        names: names,
        thumb: (r) {
          shown.add(r.id);
          return const SizedBox.shrink();
        },
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();

    expect(shown, contains('m1'));
    expect(find.text('+4'), findsOneWidget);
  });

  testWidgets('a quieted card stays on the record as a row', (tester) async {
    store.add(
        SafetyNumberChanged(id: 't', albumId: 'a', at: at, peerToken: 'noor'));
    await pump(tester);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(find.text('Compare'), findsNothing);
    expect(find.textContaining('safety number changed', findRichText: true),
        findsOneWidget);
    expect(find.text("You haven't compared it yet."), findsOneWidget);
  });

  testWidgets('every card answer is saved', (tester) async {
    store.add(
        SafetyNumberChanged(id: 't', albumId: 'a', at: at, peerToken: 'noor'));
    store.add(InvitedToAlbum(id: 'i', albumId: 'b', at: at));
    store.add(RemovedFromAlbum(
        id: 'r', albumId: 'c', at: at.subtract(const Duration(minutes: 1))));
    await pump(tester);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Okay'));
    await tester.pumpAndSettle();

    expect(store.dismissed, unorderedEquals(['t', 'i', 'r']));
  });

  testWidgets('comparing without a match leaves the card up', (tester) async {
    store.add(
        SafetyNumberChanged(id: 't', albumId: 'a', at: at, peerToken: 'noor'));
    await tester.pumpWidget(MaterialApp(
      home: ActivityScreen(
        store: store,
        names: names,
        onCompare: (_) async {},
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Compare'));
    await tester.pumpAndSettle();

    expect(store.dismissed, isEmpty);
    expect(find.text('Compare'), findsOneWidget);
  });

  testWidgets('a match during Compare turns the card into a settled row',
      (tester) async {
    final e =
        SafetyNumberChanged(id: 't', albumId: 'a', at: at, peerToken: 'noor');
    store.add(e);
    await tester.pumpWidget(MaterialApp(
      home: ActivityScreen(
        store: store,
        names: names,
        // What the real sheet does once every digit matched
        onCompare: (_) async {
          store.rows[0] = StoredActivity(
              event: e.asVerified(), seen: true, dismissed: true);
        },
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Compare'));
    await tester.pumpAndSettle();

    expect(find.text('Compare'), findsNothing);
    expect(find.textContaining('matched'), findsOneWidget);
  });

  testWidgets('a removal offers only an acknowledgement', (tester) async {
    store.add(RemovedFromAlbum(id: 'r', albumId: 'a', at: at));
    await pump(tester);

    expect(find.text('Okay'), findsOneWidget);
    expect(find.text('Delete my copy'), findsNothing);
  });

  testWidgets('a card answered before opens as a row, not a card',
      (tester) async {
    store.add(
        SafetyNumberChanged(id: 't', albumId: 'a', at: at, peerToken: 'noor'),
        dismissed: true);
    await pump(tester);

    expect(find.text('Compare'), findsNothing);
    expect(find.text("You haven't compared it yet."), findsOneWidget);
    expect(find.text("You're up to date."), findsOneWidget);
  });

  testWidgets('an empty security lane says so in the app voice',
      (tester) async {
    await pump(tester);
    expect(find.text('No security activity yet.'), findsOneWidget);
    expect(find.text('Up to date'), findsOneWidget);
    expect(
      find.text('Nothing has changed about who can read your albums.'),
      findsOneWidget,
    );
  });

  testWidgets('opening the tab marks what it showed as seen', (tester) async {
    store.add(MemberJoined(id: 'j', albumId: 'a', at: at, memberToken: 'juno'));
    await pump(tester);

    expect(await store.unseenCount(ActivityLane.security), 0);
  });

  testWidgets('the tab you did not visit stays unread', (tester) async {
    store.add(PhotosAdded(id: 'p', albumId: 'a', at: at, count: 5));
    store.add(MemberJoined(id: 'j', albumId: 'a', at: at, memberToken: 'juno'));
    await pump(tester);

    expect(await store.unseenCount(ActivityLane.security), 0);
    expect(await store.unseenCount(ActivityLane.albums), 1);

    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();

    expect(await store.unseenCount(ActivityLane.albums), 0);
  });

  testWidgets('a badge clears once its own tab has been read', (tester) async {
    store.add(PhotosAdded(id: 'p', albumId: 'a', at: at, count: 5));
    store.add(MemberJoined(id: 'j', albumId: 'a', at: at, memberToken: 'juno'));
    await pump(tester);

    expect(find.byKey(const ValueKey('attention-albums')), findsOneWidget);

    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('attention-albums')), findsNothing);
  });

  testWidgets('the shelf is told once everything has been read',
      (tester) async {
    store.add(MemberJoined(id: 'j', albumId: 'a', at: at, memberToken: 'juno'));
    unreadSeen.clear();
    await pump(tester);

    expect(unreadSeen.last, isFalse);
  });

  testWidgets('back and card buttons are full size tap targets',
      (tester) async {
    store.add(
        SafetyNumberChanged(id: 't', albumId: 'a', at: at, peerToken: 'noor'));
    await pump(tester);

    expect(tester.getSize(find.byKey(const ValueKey('activity-back'))).height,
        greaterThanOrEqualTo(48));
    for (final label in ['Compare', 'Not now']) {
      final target = find.ancestor(
          of: find.text(label), matching: find.byKey(ValueKey('card-$label')));
      expect(tester.getSize(target).height, greaterThanOrEqualTo(48),
          reason: label);
    }
  });
}
