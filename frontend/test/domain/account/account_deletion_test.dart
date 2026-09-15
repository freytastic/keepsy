import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/api/account_api.dart';
import 'package:keepsy/data/api/api_error.dart';
import 'package:keepsy/data/storage/deletion_marker.dart';
import 'package:keepsy/domain/account/account_deletion.dart';

ApiError _err(String code) =>
    ApiError(code: code, message: '', httpStatus: 409);

class _World implements AccountDeletionApi, DeletionMarkerStore {
  final log = <String>[];
  PendingDeletion? marker;
  // Each request pops the next outcome, null means accepted
  final requestOutcomes = <Object?>[];
  // Receipts the server holds
  final accepted = <String>{};
  // Each receipt check pops the next outcome, empty means answer from accepted
  final receiptOutcomes = <Object>[];
  Object? wipeError;
  // Receipts barred by an abandon
  final abandoned = <String>{};

  @override
  Future<List<DeletionAlbum>> preflight() async => const [
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

  @override
  Future<void> request(List<String> sharedAlbumIds, String receipt) async {
    log.add('request');
    expect(marker?.receipt, receipt, reason: 'the marker must precede it');
    final outcome =
        requestOutcomes.isEmpty ? null : requestOutcomes.removeAt(0);
    if (outcome is _AcceptThenFail) {
      accepted.add(receipt);
      throw const SocketException('response lost');
    }
    if (outcome is _StragglerCommits) {
      accepted.add(receipt);
      throw _err('E_AUTH');
    }
    if (outcome != null) throw outcome;
    accepted.add(receipt);
  }

  @override
  Future<bool> abandon(String receipt) async {
    log.add('abandon');
    if (accepted.contains(receipt)) return true;
    abandoned.add(receipt);
    return false;
  }

  @override
  Future<bool> receiptAccepted(String receipt) async {
    log.add('receipt');
    if (receiptOutcomes.isNotEmpty) throw receiptOutcomes.removeAt(0);
    return accepted.contains(receipt);
  }

  @override
  Future<PendingDeletion?> read() async => marker;

  @override
  Future<void> write(PendingDeletion pending) async {
    log.add(pending.accepted ? 'marker accepted' : 'marker');
    marker = pending;
  }

  @override
  Future<void> clear() async {
    log.add('clear');
    marker = null;
  }

  Future<void> wipe() async {
    log.add('wipe');
    final e = wipeError;
    if (e != null) throw e;
  }

  AccountDeletion deletion() => AccountDeletion(
        api: this,
        marker: this,
        wipe: wipe,
        random: (n) => Uint8List(n),
      );
}

class _AcceptThenFail {
  const _AcceptThenFail();
}

// The first request commits while the retry is refused for a gone session
class _StragglerCommits {
  const _StragglerCommits();
}

void main() {
  test('the plan separates albums deleted for everyone', () async {
    final plan = await _World().deletion().plan();
    expect([for (final a in plan.shared) a.albumId], ['shared']);
    expect([for (final a in plan.left) a.albumId], ['joined']);
  });

  test('an accepted request wipes, then drops the marker', () async {
    final w = _World();
    final d = w.deletion();
    expect(await d.confirm(await d.plan()), DeletionResult.deleted);
    expect(w.log, ['marker', 'request', 'marker accepted', 'wipe', 'clear']);
    expect(w.marker, isNull);
  });

  test('a stale plan bars the receipt before dropping the marker', () async {
    final w = _World()..requestOutcomes.add(_err('E_DELETION_PLAN_STALE'));
    final d = w.deletion();
    expect(await d.confirm(await d.plan()), DeletionResult.planChanged);
    expect(w.log, ['marker', 'request', 'abandon', 'clear']);
  });

  test('a lost response is resolved by the receipt and still wipes', () async {
    final w = _World()..requestOutcomes.add(const _AcceptThenFail());
    final d = w.deletion();
    expect(await d.confirm(await d.plan()), DeletionResult.deleted);
    expect(w.log, containsAllInOrder(['request', 'receipt', 'wipe', 'clear']));
    expect(w.log.where((e) => e == 'request'), hasLength(1),
        reason: 'an accepted receipt needs no second request');
  });

  test('a request that never landed is resent in the same tap', () async {
    final w = _World()..requestOutcomes.add(const SocketException('down'));
    final d = w.deletion();
    expect(await d.confirm(await d.plan()), DeletionResult.deleted);
    expect(w.log.where((e) => e == 'request'), hasLength(2));
    expect(w.accepted, hasLength(1));
  });

  test('a refused resend is explained by a first request that landed',
      () async {
    final w = _World()
      ..requestOutcomes
          .addAll([const SocketException('slow'), const _StragglerCommits()]);
    final d = w.deletion();
    expect(await d.confirm(await d.plan()), DeletionResult.deleted);
    expect(
        w.log, containsAllInOrder(['receipt', 'request', 'receipt', 'wipe']));
  });

  test('silence after a refused resend leaves the choice to the user',
      () async {
    final w = _World()
      ..requestOutcomes.addAll([const SocketException('down'), _err('E_AUTH')]);
    final d = w.deletion();
    expect(await d.confirm(await d.plan()), DeletionResult.unconfirmed);
    expect(w.marker, isNotNull);
    expect(w.log, isNot(contains('clear')));
  });

  test('offline keeps the marker and wipes nothing', () async {
    final w = _World()
      ..requestOutcomes.add(const SocketException('down'))
      ..receiptOutcomes.add(const SocketException('down'));
    final d = w.deletion();
    await expectLater(d.confirm(await d.plan()), throwsA(anything));
    expect(w.marker?.accepted, isFalse);
    expect(w.log, isNot(contains('wipe')));
  });

  test('a restart finishes an accepted deletion without the network', () async {
    final w = _World()
      ..marker = const PendingDeletion(
          receipt: 'r', sharedAlbumIds: [], accepted: true)
      ..receiptOutcomes.add(const SocketException('never asked'));
    expect(await w.deletion().resume(), DeletionResult.deleted);
    expect(w.log, ['wipe', 'clear']);
  });

  test('a restart that finds no receipt never concludes on its own', () async {
    final w = _World()
      ..marker = const PendingDeletion(
          receipt: 'r', sharedAlbumIds: ['shared'], accepted: false);
    expect(await w.deletion().resume(), DeletionResult.unconfirmed);
    expect(w.marker, isNotNull, reason: 'an old request may still commit');
    expect(w.log, ['receipt']);
  });

  test('continuing resends the same receipt only after the tap', () async {
    final w = _World()
      ..marker = const PendingDeletion(
          receipt: 'r', sharedAlbumIds: ['shared'], accepted: false);
    final d = w.deletion();
    expect(await d.continueDeleting(), DeletionResult.deleted);
    expect(w.accepted, {'r'});
    expect(w.marker, isNull);
  });

  test('keeping the account bars the receipt before forgetting it', () async {
    final w = _World()
      ..marker = const PendingDeletion(
          receipt: 'r', sharedAlbumIds: ['shared'], accepted: false);
    final d = w.deletion();
    expect(await d.keepAccount(), DeletionResult.notAccepted);
    expect(w.log, ['abandon', 'clear']);
    expect(w.abandoned, {'r'});
  });

  test('keeping the account still wipes if the old request won', () async {
    final w = _World()
      ..marker = const PendingDeletion(
          receipt: 'r', sharedAlbumIds: ['shared'], accepted: false)
      ..accepted.add('r');
    expect(await w.deletion().keepAccount(), DeletionResult.deleted);
    expect(w.log, containsAllInOrder(['abandon', 'wipe', 'clear']));
  });

  test('an incomplete wipe keeps the accepted marker for the next attempt',
      () async {
    final w = _World()..wipeError = const WipeIncomplete(['keystore']);
    final d = w.deletion();
    await expectLater(
        d.confirm(await d.plan()), throwsA(isA<WipeIncomplete>()));
    expect(w.marker?.accepted, isTrue);

    w.wipeError = null;
    expect(await d.resume(), DeletionResult.deleted);
    expect(w.marker, isNull);
  });

  group('terminal wipe', () {
    test('repeats every step until nothing is left', () async {
      var runs = 0;
      var left = ['file keepsy_vault'];
      final wipe = TerminalWipe(
        steps: [(name: 'dirs', run: () async => runs++)],
        leftovers: () async {
          final now = left;
          left = [];
          return now;
        },
        sleep: (_) async {},
      );
      await wipe.run();
      expect(runs, 2);
    });

    test('reports what failed after its last attempt', () async {
      final ran = <String>[];
      final wipe = TerminalWipe(
        steps: [
          (name: 'a', run: () async => ran.add('a')),
          (name: 'keystore', run: () async => throw StateError('native')),
          (name: 'c', run: () async => ran.add('c')),
        ],
        leftovers: () async => ['preferences'],
        attempts: 2,
        sleep: (_) async {},
      );
      await expectLater(
        wipe.run(),
        throwsA(isA<WipeIncomplete>().having(
            (e) => e.failures, 'failures', ['keystore', 'preferences'])),
      );
      expect(ran, ['a', 'c', 'a', 'c'],
          reason: 'one failure never stops the rest');
    });
  });

  test('the marker file round trips and clears', () async {
    final dir = await Directory.systemTemp.createTemp('marker');
    addTearDown(() => dir.delete(recursive: true));
    final store = DeletionMarkerFile(File('${dir.path}/$kDeletionMarkerName'));
    expect(await store.read(), isNull);
    await store.write(const PendingDeletion(
        receipt: 'abc', sharedAlbumIds: ['a1'], accepted: true));
    final back = await store.read();
    expect(back?.receipt, 'abc');
    expect(back?.sharedAlbumIds, ['a1']);
    expect(back?.accepted, isTrue);
    expect(File('${dir.path}/$kDeletionMarkerName.tmp').existsSync(), isFalse);
    await store.clear();
    expect(await store.read(), isNull);
  });

  test('an unknown outcome is not silently dropped from the plan', () {
    expect(DeletionAlbum.tryParse({'album_id': 'x', 'outcome': 'transfer'}),
        isNull);
  });
}
