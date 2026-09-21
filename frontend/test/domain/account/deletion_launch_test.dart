import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/api/account_api.dart';
import 'package:keepsy/domain/account/account_deletion.dart';
import 'package:keepsy/domain/account/deletion_launch.dart';

class _Api implements AccountDeletionApi {
  final List<DeletionAlbum> albums;
  _Api(this.albums);
  @override
  Future<List<DeletionAlbum>> preflight() async => albums;
  @override
  Future<void> request(List<String> ids, String receipt) async {}
  @override
  Future<bool> receiptAccepted(String receipt) async => false;
  @override
  Future<bool> abandon(String receipt) async => false;
}

class _Marker implements DeletionMarkerStore {
  @override
  Future<PendingDeletion?> read() async => null;
  @override
  Future<void> write(PendingDeletion pending) async {}
  @override
  Future<void> clear() async {}
}

DeletionAlbum _shared(String id) => DeletionAlbum(
      albumId: id,
      activeMemberCount: 3,
      ownMediaCount: 1,
      outcome: DeletionOutcome.deleteShared,
    );

void main() {
  AccountDeletion deletionWith(List<DeletionAlbum> albums) => AccountDeletion(
        api: _Api(albums),
        marker: _Marker(),
        wipe: () async {},
        random: (n) => throw UnimplementedError(),
      );

  // The lost-device entry point must not open the screen without a plan
  test('a launch builds the plan the screen needs', () async {
    DeletionPlan? seen;
    final result = await launchAccountDeletion(
      deletion: deletionWith(const []),
      confirmShared: (_) async => true,
      openScreen: (plan) async {
        seen = plan;
        return DeletionResult.deleted;
      },
    );

    expect(seen, isNotNull);
    expect(result, DeletionResult.deleted);
  });

  test('shared albums are confirmed before the screen opens', () async {
    var confirmed = false;
    var opened = false;
    await launchAccountDeletion(
      deletion: deletionWith([_shared('a')]),
      confirmShared: (albums) async {
        confirmed = true;
        expect(albums, hasLength(1));
        return true;
      },
      openScreen: (_) async {
        opened = true;
        return DeletionResult.deleted;
      },
    );

    expect(confirmed, isTrue);
    expect(opened, isTrue);
  });

  test('declining the shared album warning stops the deletion', () async {
    var opened = false;
    final result = await launchAccountDeletion(
      deletion: deletionWith([_shared('a')]),
      confirmShared: (_) async => false,
      openScreen: (_) async {
        opened = true;
        return DeletionResult.deleted;
      },
    );

    expect(opened, isFalse);
    expect(result, isNull);
  });

  // A changed plan must be reviewed again
  test('a changed plan is replanned and reconfirmed', () async {
    var opens = 0;
    final result = await launchAccountDeletion(
      deletion: deletionWith(const []),
      confirmShared: (_) async => true,
      openScreen: (_) async {
        opens++;
        return opens == 1 ? DeletionResult.planChanged : DeletionResult.deleted;
      },
    );

    expect(opens, 2);
    expect(result, DeletionResult.deleted);
  });

  test('a plan that never settles gives up instead of looping', () async {
    var opens = 0;
    final result = await launchAccountDeletion(
      deletion: deletionWith(const []),
      confirmShared: (_) async => true,
      openScreen: (_) async {
        opens++;
        return DeletionResult.planChanged;
      },
    );

    expect(result, isNull);
    expect(opens, 3);
  });
}
