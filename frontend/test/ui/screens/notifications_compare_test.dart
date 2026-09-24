import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:keepsy/data/storage/activity_store.dart';
import 'package:keepsy/domain/activity/activity_event.dart';
import 'package:keepsy/domain/activity/activity_sync.dart';
import 'package:keepsy/e2ee/identity_trust.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/screens/notifications_screen.dart';

const _album = '11111111-2222-3333-4444-555555555555';

class _Feed implements ActivityFeed {
  final List<StoredActivity> rows = [];
  final List<SafetyNumberChanged> resolved = [];

  @override
  Future<List<StoredActivity>> read({ActivityLane? lane}) async => [
        for (final r in rows)
          if (lane == null || r.event.lane == lane) r
      ];

  @override
  Future<void> markSeen(Iterable<String> ids) async {}

  @override
  Future<int> unseenCount(ActivityLane lane) async => 0;

  @override
  Future<void> dismiss(String id) async {}

  @override
  Future<void> resolveVerified(SafetyNumberChanged e) async {
    resolved.add(e);
    rows
      ..removeWhere((r) => r.event.id == e.id)
      ..add(StoredActivity(event: e.asVerified(), seen: true, dismissed: true));
  }
}

// Records the exact key used by each trust operation
class _Trust implements IdentityTrust {
  final List<Uint8List> numbered = [];
  final List<({Uint8List album, String token, Uint8List ik})> verified = [];
  final Set<String> alreadyVerified = {};
  bool saveFails = false;

  @override
  Future<String> safetyNumber({
    required Uint8List albumId,
    required Uint8List peerIkPub,
  }) async {
    numbered.add(peerIkPub);
    return '11111 22222 33333\n44444 55555 66666';
  }

  @override
  Future<void> markVerified({
    required Uint8List albumId,
    required String memberToken,
    required Uint8List peerIkPub,
  }) async {
    verified.add((album: albumId, token: memberToken, ik: peerIkPub));
    // Like the real store: memory moves first, then the write may fail
    resolvedHere.add('$memberToken:${String.fromCharCodes(peerIkPub)}');
    if (saveFails) {
      writeFailed = true;
      throw const VerificationNotSaved();
    }
  }

  bool writeFailed = false;

  @override
  Future<DateTime?> verifiedAt(Uint8List peerIkPub) async =>
      alreadyVerified.contains(String.fromCharCodes(peerIkPub))
          ? DateTime(2026)
          : null;

  // Resolved means verified and pinned in this album for this member
  final Set<String> resolvedHere = {};

  @override
  Future<bool> isResolved({
    required Uint8List albumId,
    required String memberToken,
    required Uint8List peerIkPub,
  }) async =>
      // Like the real one: nothing counts as resolved until it is on disk
      !writeFailed &&
      resolvedHere.contains('$memberToken:${String.fromCharCodes(peerIkPub)}');

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  final alerted = Uint8List.fromList(List.filled(32, 7));

  late _Feed feed;
  late _Trust trust;

  setUp(() {
    feed = _Feed()
      ..rows.add(StoredActivity(
        seen: false,
        event: SafetyNumberChanged(
          id: 'trust:$_album:noor:k7',
          albumId: _album,
          at: DateTime.now(),
          peerToken: 'noor',
          presentedIk: alerted,
        ),
      ));
    trust = _Trust();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: AppState()),
        Provider<ActivityFeed>.value(value: feed),
        Provider<IdentityTrust>.value(value: trust),
        Provider<ActivitySync>.value(
          value: ActivitySync(
            observe: (_) async {},
            afterEach: () async {},
            current: () => const [],
          ),
        ),
      ],
      child: const MaterialApp(home: NotificationsScreen()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a confirmed match verifies the alerted key and resolves it',
      (tester) async {
    await open(tester);

    await tester.tap(find.text('Compare'));
    await tester.pumpAndSettle();
    expect(trust.numbered.single, alerted,
        reason: 'the digits must be for the key that raised the alarm');

    await tester.tap(find.text('They match'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('They matched'));
    await tester.pumpAndSettle();

    final v = trust.verified.single;
    expect(v.ik, alerted);
    expect(v.token, 'noor');
    expect(v.album, hasLength(16));
    expect(feed.resolved.single.presentedIk, alerted);

    expect(find.text('Compare'), findsNothing);
    expect(find.text('You compared it and it matched.'), findsOneWidget);
  });

  testWidgets('saying the digits did not match resolves nothing',
      (tester) async {
    await open(tester);

    await tester.tap(find.text('Compare'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('They match'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("They didn't"));
    await tester.pumpAndSettle();

    expect(trust.verified, isEmpty);
    expect(feed.resolved, isEmpty);
  });

  // Verified from this album's own screen: opening Activity settles it
  testWidgets('a key resolved in this album is settled on open',
      (tester) async {
    trust.resolvedHere.add('noor:${String.fromCharCodes(alerted)}');
    await open(tester);

    expect(feed.resolved.single.presentedIk, alerted);
    expect(find.text('Compare'), findsNothing);
  });

  // Verified in another album while this album still pins the old key: the
  // album screen still alarms, so Activity must too
  testWidgets('a key verified only elsewhere keeps the alarm', (tester) async {
    trust.alreadyVerified.add(String.fromCharCodes(alerted));
    await open(tester);

    expect(feed.resolved, isEmpty);
    expect(find.text('Compare'), findsOneWidget);
  });

  // The album would alarm again after a restart, so Activity must not say
  // it matched
  testWidgets('a verification that did not save leaves the card up',
      (tester) async {
    trust.saveFails = true;
    await open(tester);

    await tester.tap(find.text('Compare'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('They match'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('They matched'));
    await tester.pumpAndSettle();

    expect(feed.resolved, isEmpty);
    expect(find.text('Compare'), findsOneWidget);
  });

  // A failed save moves memory only; reopening must not dismiss durable history
  testWidgets('reopening after a failed save keeps the card up',
      (tester) async {
    trust.saveFails = true;
    await open(tester);

    await tester.tap(find.text('Compare'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('They match'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('They matched'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    await open(tester);

    expect(feed.resolved, isEmpty);
    expect(find.text('Compare'), findsOneWidget);
  });
}
