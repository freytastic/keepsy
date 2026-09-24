import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/api/account_api.dart';
import 'package:keepsy/domain/account/account_deletion.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/settings/delete_account_screen.dart';
import 'package:provider/provider.dart';

class _World implements AccountDeletionApi, DeletionMarkerStore {
  final log = <String>[];
  PendingDeletion? marker;
  bool offline = false;

  @override
  Future<List<DeletionAlbum>> preflight() async {
    if (offline) throw const SocketException('offline');
    return const [
      DeletionAlbum(
          albumId: 'shared',
          activeMemberCount: 3,
          ownMediaCount: 0,
          outcome: DeletionOutcome.deleteShared),
      DeletionAlbum(
          albumId: 'joined',
          activeMemberCount: 2,
          ownMediaCount: 1,
          outcome: DeletionOutcome.leave),
    ];
  }

  @override
  Future<void> request(List<String> sharedAlbumIds, String receipt) async =>
      log.add('request $sharedAlbumIds');

  @override
  Future<bool> abandon(String receipt) async => false;

  @override
  Future<bool> receiptAccepted(String receipt) async => true;

  @override
  Future<PendingDeletion?> read() async => marker;

  @override
  Future<void> write(PendingDeletion pending) async => marker = pending;

  @override
  Future<void> clear() async => marker = null;

  AccountDeletion deletion() => AccountDeletion(
        api: this,
        marker: this,
        wipe: () async => log.add('wipe'),
        random: (n) => Uint8List(n),
      );
}

Future<void> _pump(WidgetTester tester, _World world) async {
  await tester.pumpWidget(ChangeNotifierProvider(
    create: (_) => AppState(),
    child: MaterialApp(
      home: DeleteAccountScreen(deletion: world.deletion()),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('a shared album must be ticked before holding deletes',
      (tester) async {
    final world = _World();
    await _pump(tester, world);

    expect(find.text('These will be deleted for everyone'), findsOneWidget);
    expect(find.text('3 people'), findsOneWidget);
    expect(find.text('Tick each album to continue'), findsOneWidget);

    final hold = find.text('Delete account').last;
    final early = await tester.startGesture(tester.getCenter(hold));
    for (var i = 0; i < 21; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await early.up();
    await tester.pump();
    expect(world.log, isEmpty);

    await tester.tap(find.text('3 people'));
    await tester.pump();
    expect(find.text('Press and hold to delete'), findsOneWidget);

    final brief = await tester.startGesture(tester.getCenter(hold));
    await tester.pump(const Duration(milliseconds: 600));
    await brief.up();
    await tester.pumpAndSettle();
    expect(world.log, isEmpty, reason: 'letting go early must not delete');

    final held = await tester.startGesture(tester.getCenter(hold));
    for (var i = 0; i < 21; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await held.up();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(world.log, contains('request [shared]'));
  });

  testWidgets('an unreachable plan offers a retry', (tester) async {
    final world = _World()..offline = true;
    await _pump(tester, world);

    expect(find.text("Couldn't reach Keepsy."), findsOneWidget);

    world.offline = false;
    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump();
    expect(find.text('These will be deleted for everyone'), findsOneWidget);
  });
}
