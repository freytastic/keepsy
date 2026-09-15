import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/expected_ik_resolver.dart';
import 'package:keepsy/e2ee/rotation_recovery.dart';

Uint8List _album([int s = 0xA1]) => Uint8List.fromList(List<int>.filled(16, s));

class _Harness {
  bool required = true;
  bool admin = true;
  bool checkThrows = false;
  int checks = 0;
  int recoverCalls = 0;
  final errors = <Object>[];
  Completer<void>? recoverGate;
  Completer<void>? checkGate;
  int checksInFlight = 0;
  int maxChecksInFlight = 0;
  final sleeps = <Duration>[];
  final statuses = <RotationStatus>[];
  final reconciled = <String>[];
  bool recoverRotates = true;
  bool reconcileThrows = false;
  late final RotationRecoveryScheduler scheduler;

  _Harness() {
    scheduler = RotationRecoveryScheduler(
      isRotationRequired: (_) async {
        checks++;
        checksInFlight++;
        if (checksInFlight > maxChecksInFlight) {
          maxChecksInFlight = checksInFlight;
        }
        try {
          final gate = checkGate;
          if (gate != null) await gate.future;
          if (checkThrows) throw Exception('offline');
          return required;
        } finally {
          checksInFlight--;
        }
      },
      canRotate: (_) => admin,
      recover: (_) async {
        recoverCalls++;
        final gate = recoverGate;
        if (gate != null) await gate.future;
        if (errors.isNotEmpty) throw errors.removeAt(0);
        required = false;
        return recoverRotates;
      },
      reconcile: (album) async {
        reconciled.add(album.first.toRadixString(16));
        if (reconcileThrows) throw Exception('offline');
      },
      sleep: (d) async => sleeps.add(d),
    );
    scheduler.status.listen(statuses.add);
  }

  List<RotationPhase> get phases => [for (final s in statuses) s.phase];
}

// Broadcast events land a microtask after the emit
Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test('an album that owes nothing reports nothing', () async {
    final h = _Harness()..required = false;
    await h.scheduler.request(_album());
    await _flush();
    expect(h.statuses, isEmpty);
    expect(h.recoverCalls, 0);
  });

  test('a member device only waits for the admin', () async {
    final h = _Harness()..admin = false;
    await h.scheduler.request(_album());
    await _flush();
    expect(h.phases, [RotationPhase.waiting]);
    expect(h.recoverCalls, 0);
  });

  test('the admin device rotates and clears', () async {
    final h = _Harness();
    await h.scheduler.request(_album());
    await _flush();
    expect(h.phases, [RotationPhase.rotating, RotationPhase.clear]);
    expect(h.recoverCalls, 1);
  });

  test('a transient failure retries after a backoff', () async {
    final h = _Harness()..errors.add(Exception('network'));
    await h.scheduler.request(_album());
    await _flush();
    expect(h.phases,
        [RotationPhase.rotating, RotationPhase.rotating, RotationPhase.clear]);
    expect(h.sleeps, [const Duration(seconds: 2)]);
  });

  test('an unconfirmed identity fails at once without retrying', () async {
    final h = _Harness()
      ..errors.add(MissingIdentityPinException(Uint8List(32)));
    await h.scheduler.request(_album());
    await _flush();
    expect(h.phases, [RotationPhase.rotating, RotationPhase.failed]);
    expect(h.statuses.last.failure, RotationFailure.identityUnconfirmed);
    expect(h.recoverCalls, 1);
    expect(h.sleeps, isEmpty);
  });

  test('exhausted retries leave the album failed and owed', () async {
    final h = _Harness()
      ..errors.addAll([Exception('a'), Exception('b'), Exception('c')]);
    await h.scheduler.request(_album());
    await _flush();
    expect(h.recoverCalls, 3);
    expect(h.phases.last, RotationPhase.failed);
    expect(h.statuses.last.failure, RotationFailure.unavailable);
    expect(h.scheduler.phaseOf(_album()), RotationPhase.failed);
  });

  test('triggers that land mid run collapse into one follow up pass', () async {
    final h = _Harness();
    final gate = h.recoverGate = Completer<void>();
    final runs = [
      h.scheduler.request(_album()),
      h.scheduler.request(_album()),
      h.scheduler.request(_album()),
    ];
    await _flush();
    expect(h.recoverCalls, 1);

    gate.complete();
    await Future.wait(runs);
    expect(h.recoverCalls, 1);
    expect(h.checks, 2, reason: 'one run plus a single coalesced re check');
  });

  test('an unreachable server keeps the last known state', () async {
    final h = _Harness()..admin = false;
    await h.scheduler.request(_album());
    h.checkThrows = true;
    await h.scheduler.request(_album());
    await _flush();
    expect(h.phases, [RotationPhase.waiting]);
    expect(h.scheduler.phaseOf(_album()), RotationPhase.waiting);
  });

  test('the launch sweep checks at most two albums at a time', () async {
    final h = _Harness()..required = false;
    final gate = h.checkGate = Completer<void>();
    final sweep =
        h.scheduler.checkAll([for (var i = 1; i <= 5; i++) _album(i)]);
    await _flush();
    expect(h.checksInFlight, 2);

    gate.complete();
    await sweep;
    expect(h.checks, 5);
    expect(h.maxChecksInFlight, 2);
  });

  test('an installed epoch re checks only albums that owe a rotation',
      () async {
    final h = _Harness()..admin = false;
    await h.scheduler.request(_album());
    final before = h.checks;

    h.required = false;
    h.scheduler.onEpochInstalled(_album(0xB2));
    await _flush();
    expect(h.checks, before);

    h.scheduler.onEpochInstalled(_album());
    await _flush();
    await _flush();
    expect(h.checks, before + 1);
    expect(h.phases, [RotationPhase.waiting, RotationPhase.clear]);
  });

  test('a settled rotation installs the winning epoch', () async {
    final h = _Harness();
    await h.scheduler.request(_album(0xA1));
    await _flush();

    expect(h.phases, [RotationPhase.rotating, RotationPhase.clear]);
    expect(h.reconciled, ['a1'],
        reason: 'queued photos resume only once that epoch is installed');
  });

  test('losing the race still installs the winning epoch', () async {
    final h = _Harness()..recoverRotates = false;
    await h.scheduler.request(_album(0xA1));
    await _flush();

    expect(h.reconciled, ['a1']);
  });

  test('a member device reconciles once the debt clears', () async {
    final h = _Harness()..admin = false;
    await h.scheduler.request(_album(0xA1));
    expect(h.reconciled, isEmpty, reason: 'nothing has rotated yet');

    h.required = false;
    await h.scheduler.request(_album(0xA1));
    await _flush();

    expect(h.reconciled, ['a1']);
    expect(h.phases, [RotationPhase.waiting, RotationPhase.clear]);
  });

  test('an album that owed nothing is not reconciled', () async {
    final h = _Harness()..required = false;
    await h.scheduler.request(_album(0xA1));
    await _flush();

    expect(h.reconciled, isEmpty);
  });

  test('a reconcile failure does not resurrect the debt', () async {
    final h = _Harness()..reconcileThrows = true;
    await h.scheduler.request(_album(0xA1));
    await _flush();

    expect(h.scheduler.phaseOf(_album(0xA1)), RotationPhase.clear);
    expect(h.phases.last, RotationPhase.clear);
  });

  test('a forgotten album is not re checked on a later epoch', () async {
    final h = _Harness()..admin = false;
    await h.scheduler.request(_album());
    final before = h.checks;

    h.scheduler.forget(_album());
    h.scheduler.onEpochInstalled(_album());
    await _flush();
    expect(h.checks, before);
    expect(h.scheduler.phaseOf(_album()), RotationPhase.clear);
  });
}
