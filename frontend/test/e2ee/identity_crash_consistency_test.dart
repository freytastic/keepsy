import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/e2ee/identity_label_map.dart';
import 'package:keepsy/e2ee/prekey_api.dart';
import 'package:keepsy/e2ee/prekey_bundle.dart';
import 'package:keepsy/secure_store/key_handle.dart';
import 'package:keepsy/secure_store/key_handle_adapter.dart';

import '../_sodium_setup.dart';
import '../secure_store/mock_secure_key_store.dart';
import 'identity_label_map_test_helpers.dart';

// Covers ambiguous publication outcomes and local key addressability
class _Api implements PrekeyApi {
  final List<List<PrekeyOpk>> replenishBatches = [];
  int countResponse = 0;
  int rotateCalls = 0;
  PrekeyApiException? replenishError;
  PrekeyApiException? rotateError;
  OwnKeys own = OwnKeys(
      ikPub: Uint8List(0),
      lkPub: Uint8List(0),
      spkPub: Uint8List(0),
      spkTs: null);
  // Captures a committed rotation even when its response is lost
  Uint8List? acceptedSpkPub;
  int? acceptedSpkTs;

  @override
  Future<int> opkCount() async => countResponse;

  @override
  Future<void> replenishOpks(
      {required List<PrekeyOpk> opks, required Uint8List replenishSig}) async {
    if (replenishError != null) {
      final e = replenishError!;
      replenishError = null;
      throw e;
    }
    replenishBatches.add(List.of(opks));
  }

  @override
  Future<void> rotateSpk(
      {required Uint8List spkPub,
      required Uint8List spkSig,
      required int spkTs,
      required Uint8List rotationSig}) async {
    rotateCalls++;
    // Model a server commit followed by a lost response
    acceptedSpkPub = Uint8List.fromList(spkPub);
    acceptedSpkTs = spkTs;
    if (rotateError != null) {
      final e = rotateError!;
      rotateError = null;
      throw e;
    }
  }

  @override
  Future<void> upsertIdentity(
      {required Uint8List ikPub,
      required Uint8List lkPub,
      required Uint8List spkPub,
      required Uint8List spkSig,
      required int spkTs}) async {}

  @override
  Future<OwnKeys> fetchOwnKeys() async => own;

  @override
  Future<PrekeyBundle> fetchPrekeyBundle(String userId) =>
      throw UnimplementedError();

  @override
  Future<PrekeyBundle> fetchPrekeyBundleByHandle(String handle) =>
      throw UnimplementedError();
}

Future<
    ({
      IdentityService svc,
      MockSecureKeyStore store,
      IdentityLabelMap labels,
      _Api api,
    })> _boot({DateTime Function()? now}) async {
  final store = MockSecureKeyStore();
  await store.initialize();
  final labels = makeInMemoryLabelMap();
  await labels.load();
  final api = _Api();
  final svc = IdentityService(
      store: store, labels: labels, api: api, now: now ?? DateTime.now);
  return (svc: svc, store: store, labels: labels, api: api);
}

Future<Uint8List> _pubOf(
    MockSecureKeyStore store, String handleId, String label) async {
  return store.use<Uint8List>(KeyHandle(id: handleId, label: label),
      (priv) async {
    final kp = await KeyHandleAdapter.toX25519(priv);
    return kp.publicKey;
  });
}

typedef _Boot = ({
  IdentityService svc,
  MockSecureKeyStore store,
  IdentityLabelMap labels,
  _Api api,
});

// Drives a rotation to the unsettled state and returns the pending handle
Future<String> _stall(_Boot r, void Function() advance) async {
  advance();
  r.api.rotateError = const PrekeyApiException(
      code: 'E_INTERNAL', message: 'boom', httpStatus: 500);
  await expectLater(
      r.svc.ensureSpkRotated(), throwsA(isA<PrekeyApiException>()));
  return r.labels.handleId(kLabelSpkPending)!;
}

// Supplies the local identity required before SPK reconciliation
Future<(Uint8List, Uint8List)> _ownIkLk(IdentityService svc) async {
  final ik = await svc.currentIkPub();
  final lk = await svc.useLk<Uint8List>(
      (p) async => (await KeyHandleAdapter.toX25519(p)).publicKey);
  return (ik, lk);
}

void main() {
  setUpAll(ensureSodium);

  group('gap D : OPK replenish', () {
    test(
        'labels are persisted before publish, so a failed publish never leaves '
        'an advertised key without an addressable private half', () async {
      final r = await _boot();
      await r.svc.bootstrap();
      final before = r.labels.labelsWithPrefix(kLabelOpkPrefix).length;

      r.api.countResponse = 0;
      r.api.replenishError = const PrekeyApiException(
          code: 'E_INTERNAL', message: 'boom', httpStatus: 500);
      await expectLater(
          r.svc.replenishOpks(), throwsA(isA<PrekeyApiException>()));

      final after = r.labels.labelsWithPrefix(kLabelOpkPrefix);
      expect(after.length, greaterThan(before),
          reason: 'every generated OPK must be addressable by label');
      for (final l in after) {
        expect(r.labels.handleId(l), isNotNull);
      }
    });

    test(
        'a retry after an ambiguous failure allocates FRESH indices instead of '
        'reminting different keys under indices the server may already hold',
        () async {
      final r = await _boot();
      await r.svc.bootstrap();

      r.api.countResponse = 0;
      r.api.replenishError = const PrekeyApiException(
          code: 'E_INTERNAL', message: 'boom', httpStatus: 500);
      await expectLater(
          r.svc.replenishOpks(), throwsA(isA<PrekeyApiException>()));

      final burned = r.labels
          .labelsWithPrefix(kLabelOpkPrefix)
          .map((l) => int.parse(l.substring(kLabelOpkPrefix.length)))
          .toSet();

      await r.svc.replenishOpks();
      expect(r.api.replenishBatches, isNotEmpty);
      for (final o in r.api.replenishBatches.last) {
        expect(burned.contains(o.idx), isFalse,
            reason: 'idx ${o.idx} was already generated locally and may exist '
                'server-side under a different key');
      }
    });
  });

  group('gap B : initial OPK publication', () {
    test(
        'a lost initial-OPK ack converges on the next launch instead of '
        'bricking the device', () async {
      final r = await _boot();
      r.api.replenishError = const PrekeyApiException(
          code: 'E_INTERNAL', message: 'dropped', httpStatus: 500);
      await expectLater(r.svc.bootstrap(), throwsA(isA<PrekeyApiException>()));
      expect(await r.svc.isBootstrapped(), isFalse);

      // The next launch must reach the identical resend.
      await r.svc.bootstrap();
      expect(await r.svc.isBootstrapped(), isTrue);
    });

    test(
        'steady replenish is blocked until initial publication is acknowledged',
        () async {
      final r = await _boot();
      r.api.replenishError = const PrekeyApiException(
          code: 'E_INTERNAL', message: 'dropped', httpStatus: 500);
      await expectLater(r.svc.bootstrap(), throwsA(isA<PrekeyApiException>()));
      final labelsAfterBootstrap =
          r.labels.labelsWithPrefix(kLabelOpkPrefix).length;

      // landing_screen swallows the bootstrap failure and calls this next
      r.api.countResponse = kBootstrapOpkPool;
      await r.svc
          .replenishOpks(target: kTargetOpkPool, trigger: kTargetOpkPool);

      expect(r.labels.labelsWithPrefix(kLabelOpkPrefix).length,
          labelsAfterBootstrap,
          reason: 'replenishing over a half-published identity is what grew '
              'the label set past the resume check and bricked the device');
      expect(r.api.replenishBatches, isEmpty);
    });

    test('resume selects OPKs 0..4 even when higher indices already exist',
        () async {
      final r = await _boot();
      r.api.replenishError = const PrekeyApiException(
          code: 'E_INTERNAL', message: 'dropped', httpStatus: 500);
      await expectLater(r.svc.bootstrap(), throwsA(isA<PrekeyApiException>()));

      // model a device that already grew past the bootstrap pool before the fix
      for (var i = kBootstrapOpkPool; i < kTargetOpkPool; i++) {
        await r.labels.set('$kLabelOpkPrefix$i', 'stale-handle-$i');
      }

      await r.svc.bootstrap();

      expect(await r.svc.isBootstrapped(), isTrue);
      final batch = r.api.replenishBatches.last;
      expect(batch.map((o) => o.idx).toList(),
          List.generate(kBootstrapOpkPool, (i) => i),
          reason: 'the initial batch is exactly 0..4, not every label present');
    });
  });

  group('gap C : SPK rotation', () {
    // 30d gate: bootstrap at t0, rotate at t0+31d
    final t0 = DateTime.utc(2026, 5, 4, 12);

    test('the new key is addressable under pending BEFORE the server call',
        () async {
      var clock = t0;
      final r = await _boot(now: () => clock);
      await r.svc.bootstrap();
      clock = t0.add(const Duration(days: 31));

      r.api.rotateError = const PrekeyApiException(
          code: 'E_INTERNAL', message: 'boom', httpStatus: 500);
      await expectLater(
          r.svc.ensureSpkRotated(), throwsA(isA<PrekeyApiException>()));

      final pending = r.labels.handleId(kLabelSpkPending);
      expect(pending, isNotNull,
          reason: 'the key the server may have accepted must be addressable');
      final pendingPub = await _pubOf(r.store, pending!, kLabelSpkPending);
      expect(pendingPub, equals(r.api.acceptedSpkPub),
          reason: 'pending must hold exactly the key that was sent');
    });

    test(
        'a clean rotation promotes pending to current, demotes the old current '
        'to previous, and clears pending', () async {
      var clock = t0;
      final r = await _boot(now: () => clock);
      await r.svc.bootstrap();
      final oldCurrent = r.labels.handleId(kLabelSpkCurrent);

      clock = t0.add(const Duration(days: 31));
      await r.svc.ensureSpkRotated();

      expect(r.labels.handleId(kLabelSpkPending), isNull);
      expect(r.labels.handleId(kLabelSpkPrevious), oldCurrent);
      expect(r.labels.handleId(kLabelSpkCurrent), isNot(oldCurrent));
      expect(await r.labels.getSpkTs(),
          clock.toUtc().millisecondsSinceEpoch ~/ 1000);
    });

    test(
        'reconcile finishes the promotion when the server holds the pending key',
        () async {
      var clock = t0;
      final r = await _boot(now: () => clock);
      await r.svc.bootstrap();
      final oldCurrent = r.labels.handleId(kLabelSpkCurrent);

      clock = t0.add(const Duration(days: 31));
      r.api.rotateError = const PrekeyApiException(
          code: 'E_INTERNAL', message: 'boom', httpStatus: 500);
      await expectLater(
          r.svc.ensureSpkRotated(), throwsA(isA<PrekeyApiException>()));
      final pending = r.labels.handleId(kLabelSpkPending);

      // the server did accept it; this device just never saw the response
      final (myIk, myLk) = await _ownIkLk(r.svc);
      r.api.own = OwnKeys(
          ikPub: myIk,
          lkPub: myLk,
          spkPub: r.api.acceptedSpkPub!,
          spkTs: r.api.acceptedSpkTs);

      await r.svc.reconcilePendingSpk();

      expect(r.labels.handleId(kLabelSpkCurrent), pending);
      expect(r.labels.handleId(kLabelSpkPrevious), oldCurrent);
      expect(r.labels.handleId(kLabelSpkPending), isNull);
      expect(await r.labels.getSpkTs(), r.api.acceptedSpkTs);
    });

    test(
        'reconcile discards pending when the server still holds the current key',
        () async {
      var clock = t0;
      final r = await _boot(now: () => clock);
      await r.svc.bootstrap();
      final oldCurrent = r.labels.handleId(kLabelSpkCurrent)!;
      final currentPub = await _pubOf(r.store, oldCurrent, kLabelSpkCurrent);
      final tsBefore = await r.labels.getSpkTs();

      clock = t0.add(const Duration(days: 31));
      r.api.rotateError = const PrekeyApiException(
          code: 'E_INTERNAL', message: 'boom', httpStatus: 500);
      await expectLater(
          r.svc.ensureSpkRotated(), throwsA(isA<PrekeyApiException>()));

      // the rotation never landed
      final (myIk, myLk) = await _ownIkLk(r.svc);
      r.api.own = OwnKeys(
          ikPub: myIk, lkPub: myLk, spkPub: currentPub, spkTs: tsBefore);

      await r.svc.reconcilePendingSpk();

      expect(r.labels.handleId(kLabelSpkPending), isNull);
      expect(r.labels.handleId(kLabelSpkCurrent), oldCurrent);
      expect(await r.labels.getSpkTs(), tsBefore);
    });

    test(
        'a conflict archives the unacknowledged key, records the server ts, and '
        'the recovery rotation beats it even in the same second', () async {
      var clock = t0;
      final r = await _boot(now: () => clock);
      await r.svc.bootstrap();
      final (myIk, myLk) = await _ownIkLk(r.svc);
      final pending =
          await _stall(r, () => clock = t0.add(const Duration(days: 31)));

      // same account, an SPK we never held : recoverable
      final serverTs = clock.toUtc().millisecondsSinceEpoch ~/ 1000;
      r.api.own = OwnKeys(
          ikPub: myIk,
          lkPub: myLk,
          spkPub: Uint8List(32)..fillRange(0, 32, 0x5A),
          spkTs: serverTs);

      await expectLater(r.svc.reconcilePendingSpk(),
          throwsA(isA<SpkReconciliationConflict>()));

      expect(r.labels.handleId(kLabelSpkPending), isNull);
      expect(r.labels.handleId(kLabelSpkArchived), pending,
          reason: 'the unacknowledged key is archived, never deleted');
      expect(await r.svc.spkConflictTs(), serverTs);

      await r.svc.ensureSpkRotated();
      expect(r.api.acceptedSpkTs, greaterThan(serverTs),
          reason: 'an unknown rotation in this same second must not deadlock '
              'the replacement on monotonicity');
      expect(await r.svc.spkConflictTs(), isNull,
          reason: 'cleared only once the replacement is promoted');
      expect(r.labels.handleId(kLabelSpkPending), isNull);
    });

    // Cover identity divergence before both SPK-match branches
    test('identity divergence blocks even when the server SPK matches pending',
        () async {
      var clock = t0;
      final r = await _boot(now: () => clock);
      await r.svc.bootstrap();
      final oldCurrent = r.labels.handleId(kLabelSpkCurrent);
      final pending =
          await _stall(r, () => clock = t0.add(const Duration(days: 31)));

      r.api.own = OwnKeys(
          ikPub: Uint8List(32)..fillRange(0, 32, 0x11),
          lkPub: Uint8List(32)..fillRange(0, 32, 0x22),
          spkPub: r.api.acceptedSpkPub!, // matches pending
          spkTs: r.api.acceptedSpkTs);

      await expectLater(r.svc.reconcilePendingSpk(),
          throwsA(isA<IdentityDivergenceException>()));

      expect(r.labels.handleId(kLabelSpkPending), pending,
          reason: 'must not promote into a diverged account');
      expect(r.labels.handleId(kLabelSpkCurrent), oldCurrent);
    });

    test('identity divergence blocks even when the server SPK matches current',
        () async {
      var clock = t0;
      final r = await _boot(now: () => clock);
      await r.svc.bootstrap();
      final oldCurrent = r.labels.handleId(kLabelSpkCurrent)!;
      final currentPub = await _pubOf(r.store, oldCurrent, kLabelSpkCurrent);
      final pending =
          await _stall(r, () => clock = t0.add(const Duration(days: 31)));

      r.api.own = OwnKeys(
          ikPub: Uint8List(32)..fillRange(0, 32, 0x11),
          lkPub: Uint8List(32)..fillRange(0, 32, 0x22),
          spkPub: currentPub, // matches current
          spkTs: 1);

      await expectLater(r.svc.reconcilePendingSpk(),
          throwsA(isA<IdentityDivergenceException>()));

      expect(r.labels.handleId(kLabelSpkPending), pending,
          reason: 'must not delete the pending key in a diverged account');
    });

    test(
        'identity divergence stays blocked : nothing archived, nothing '
        'republished', () async {
      var clock = t0;
      final r = await _boot(now: () => clock);
      await r.svc.bootstrap();
      final pending =
          await _stall(r, () => clock = t0.add(const Duration(days: 31)));
      final callsBefore = r.api.rotateCalls;

      // A different account identity is not a rotation conflict
      r.api.own = OwnKeys(
          ikPub: Uint8List(32)..fillRange(0, 32, 0x11),
          lkPub: Uint8List(32)..fillRange(0, 32, 0x22),
          spkPub: Uint8List(32)..fillRange(0, 32, 0x33),
          spkTs: clock.toUtc().millisecondsSinceEpoch ~/ 1000);

      await expectLater(r.svc.reconcilePendingSpk(),
          throwsA(isA<IdentityDivergenceException>()));

      expect(r.labels.handleId(kLabelSpkPending), pending,
          reason: 'pending untouched : rotation stays deliberately blocked');
      await r.svc.ensureSpkRotated();
      expect(r.api.rotateCalls, callsBefore,
          reason: 'must not republish over a diverged identity');
    });

    test(
        'a server ts too far ahead to beat inside the skew window defers the '
        'recovery until wall clock catches up', () async {
      var clock = t0;
      final r = await _boot(now: () => clock);
      await r.svc.bootstrap();
      final (myIk, myLk) = await _ownIkLk(r.svc);
      await _stall(r, () => clock = t0.add(const Duration(days: 31)));

      final nowSec = clock.toUtc().millisecondsSinceEpoch ~/ 1000;
      r.api.own = OwnKeys(
          ikPub: myIk,
          lkPub: myLk,
          spkPub: Uint8List(32)..fillRange(0, 32, 0x5A),
          spkTs: nowSec + 3600); // an hour ahead : unbeatable within ±5 min
      await expectLater(r.svc.reconcilePendingSpk(),
          throwsA(isA<SpkReconciliationConflict>()));

      final callsBefore = r.api.rotateCalls;
      await r.svc.ensureSpkRotated();
      expect(r.api.rotateCalls, callsBefore,
          reason: 'a stamp not yet beatable must not be retried every launch');
    });

    test(
        'a promotion interrupted after current moved must not overwrite '
        'previous with the pending handle', () async {
      var clock = t0;
      final r = await _boot(now: () => clock);
      await r.svc.bootstrap();
      final oldCurrent = r.labels.handleId(kLabelSpkCurrent)!;

      clock = t0.add(const Duration(days: 31));
      r.api.rotateError = const PrekeyApiException(
          code: 'E_INTERNAL', message: 'boom', httpStatus: 500);
      await expectLater(
          r.svc.ensureSpkRotated(), throwsA(isA<PrekeyApiException>()));
      final pending = r.labels.handleId(kLabelSpkPending)!;

      // replay the crash: previous + current already moved, pending not cleared
      await r.labels.set(kLabelSpkPrevious, oldCurrent);
      await r.labels.set(kLabelSpkCurrent, pending);

      final (myIk, myLk) = await _ownIkLk(r.svc);
      r.api.own = OwnKeys(
          ikPub: myIk,
          lkPub: myLk,
          spkPub: r.api.acceptedSpkPub!,
          spkTs: r.api.acceptedSpkTs);

      await r.svc.reconcilePendingSpk();

      expect(r.labels.handleId(kLabelSpkCurrent), pending);
      expect(r.labels.handleId(kLabelSpkPrevious), oldCurrent,
          reason: 'previous must still be the real predecessor');
      expect(r.labels.handleId(kLabelSpkPending), isNull);
    });

    test(
        'an unresolved pending rotation blocks a second rotation from '
        'overwriting it', () async {
      var clock = t0;
      final r = await _boot(now: () => clock);
      await r.svc.bootstrap();

      clock = t0.add(const Duration(days: 31));
      r.api.rotateError = const PrekeyApiException(
          code: 'E_INTERNAL', message: 'boom', httpStatus: 500);
      await expectLater(
          r.svc.ensureSpkRotated(), throwsA(isA<PrekeyApiException>()));
      final pending = r.labels.handleId(kLabelSpkPending);
      final callsAfterFirst = r.api.rotateCalls;

      // A pending key must block another rotation.
      clock = t0.add(const Duration(days: 62));
      await r.svc.ensureSpkRotated();

      expect(r.labels.handleId(kLabelSpkPending), pending);
      expect(r.api.rotateCalls, callsAfterFirst);
    });

    test(
        'a second conflict replaces the archive and never deletes the key it '
        'is archiving', () async {
      var clock = t0;
      final r = await _boot(now: () => clock);
      await r.svc.bootstrap();
      final (myIk, myLk) = await _ownIkLk(r.svc);
      OwnKeys unknown(int ts) => OwnKeys(
          ikPub: myIk,
          lkPub: myLk,
          spkPub: Uint8List(32)..fillRange(0, 32, 0x5A),
          spkTs: ts);

      final first =
          await _stall(r, () => clock = t0.add(const Duration(days: 31)));
      r.api.own = unknown(clock.toUtc().millisecondsSinceEpoch ~/ 1000);
      await expectLater(r.svc.reconcilePendingSpk(),
          throwsA(isA<SpkReconciliationConflict>()));
      expect(r.labels.handleId(kLabelSpkArchived), first);

      // the recovery rotation also comes back unacknowledged, and the server
      // still advertises something we have never held
      final second =
          await _stall(r, () => clock = clock.add(const Duration(days: 31)));
      expect(second, isNot(first));
      r.api.own = unknown(clock.toUtc().millisecondsSinceEpoch ~/ 1000);
      await expectLater(r.svc.reconcilePendingSpk(),
          throwsA(isA<SpkReconciliationConflict>()));

      expect(r.labels.handleId(kLabelSpkArchived), second,
          reason: 'retention is one key : the newest unacknowledged one');
      // The newly archived key must remain readable
      final archivedPub = await _pubOf(r.store, second, kLabelSpkArchived);
      expect(archivedPub.length, 32);
    });

    test('an aliased archive/pending state does not delete its own key',
        () async {
      var clock = t0;
      final r = await _boot(now: () => clock);
      await r.svc.bootstrap();
      final (myIk, myLk) = await _ownIkLk(r.svc);
      final pending =
          await _stall(r, () => clock = t0.add(const Duration(days: 31)));

      // replay a crash between the two label writes: both point at one handle
      await r.labels.set(kLabelSpkArchived, pending);
      r.api.own = OwnKeys(
          ikPub: myIk,
          lkPub: myLk,
          spkPub: Uint8List(32)..fillRange(0, 32, 0x5A),
          spkTs: clock.toUtc().millisecondsSinceEpoch ~/ 1000);

      await expectLater(r.svc.reconcilePendingSpk(),
          throwsA(isA<SpkReconciliationConflict>()));

      expect(r.labels.handleId(kLabelSpkArchived), pending);
      final archivedPub = await _pubOf(r.store, pending, kLabelSpkArchived);
      expect(archivedPub.length, 32,
          reason: 'the retry must not delete the handle it is archiving');
    });

    test(
        'two concurrent settles mint exactly ONE recovery rotation, not two '
        'competing pending keys', () async {
      var clock = t0;
      final r = await _boot(now: () => clock);
      await r.svc.bootstrap();
      final (myIk, myLk) = await _ownIkLk(r.svc);
      await _stall(r, () => clock = t0.add(const Duration(days: 31)));

      r.api.own = OwnKeys(
          ikPub: myIk,
          lkPub: myLk,
          spkPub: Uint8List(32)..fillRange(0, 32, 0x5A),
          spkTs: clock.toUtc().millisecondsSinceEpoch ~/ 1000);
      final callsBefore = r.api.rotateCalls;

      // landing hygiene and the realtime connection both reach this at once
      await Future.wait([r.svc.settleSpkState(), r.svc.settleSpkState()]);

      expect(r.api.rotateCalls, callsBefore + 1,
          reason:
              'both callers observe the same conflict; rotating twice would '
              'submit two keys and promote out of response order');
      expect(r.labels.handleId(kLabelSpkPending), isNull);
      expect(await r.svc.spkConflictTs(), isNull,
          reason: 'the single recovery rotation resolved the conflict');
    });

    // Mixed public entry points must share the same transition lock
    test('settle + ensure running together mint exactly one recovery rotation',
        () async {
      var clock = t0;
      final r = await _boot(now: () => clock);
      await r.svc.bootstrap();
      final (myIk, myLk) = await _ownIkLk(r.svc);
      await _stall(r, () => clock = t0.add(const Duration(days: 31)));

      r.api.own = OwnKeys(
          ikPub: myIk,
          lkPub: myLk,
          spkPub: Uint8List(32)..fillRange(0, 32, 0x5A),
          spkTs: clock.toUtc().millisecondsSinceEpoch ~/ 1000);
      final callsBefore = r.api.rotateCalls;

      await Future.wait([
        r.svc.settleSpkState(),
        r.svc.ensureSpkRotated().catchError((_) {}),
      ]);

      expect(r.api.rotateCalls, callsBefore + 1,
          reason: 'separate per-method guards would let both pass the pending '
              'check and mint competing keys');
      expect(r.labels.handleId(kLabelSpkPending), isNull);
    });

    test('settle + reconcile running together resolve the pending key once',
        () async {
      var clock = t0;
      final r = await _boot(now: () => clock);
      await r.svc.bootstrap();
      final (myIk, myLk) = await _ownIkLk(r.svc);
      final pending =
          await _stall(r, () => clock = t0.add(const Duration(days: 31)));

      // the rotation did land : both entrypoints should agree on promotion
      r.api.own = OwnKeys(
          ikPub: myIk,
          lkPub: myLk,
          spkPub: r.api.acceptedSpkPub!,
          spkTs: r.api.acceptedSpkTs);
      final callsBefore = r.api.rotateCalls;

      await Future.wait([
        r.svc.settleSpkState(),
        r.svc.reconcilePendingSpk().catchError((_) {}),
      ]);

      expect(r.labels.handleId(kLabelSpkCurrent), pending);
      expect(r.labels.handleId(kLabelSpkPending), isNull);
      expect(r.api.rotateCalls, callsBefore,
          reason: 'a promotion is not a reason to rotate again');
    });

    test('two concurrent rotations collapse into one', () async {
      var clock = t0;
      final r = await _boot(now: () => clock);
      await r.svc.bootstrap();
      final callsBefore = r.api.rotateCalls;

      clock = t0.add(const Duration(days: 31));
      await Future.wait([r.svc.ensureSpkRotated(), r.svc.ensureSpkRotated()]);

      expect(r.api.rotateCalls, callsBefore + 1);
      expect(r.labels.handleId(kLabelSpkPending), isNull);
    });

    test('reconcile is a no-op when nothing is pending', () async {
      final r = await _boot();
      await r.svc.bootstrap();
      final current = r.labels.handleId(kLabelSpkCurrent);

      await r.svc.reconcilePendingSpk();

      expect(r.labels.handleId(kLabelSpkCurrent), current);
      expect(r.labels.handleId(kLabelSpkPending), isNull);
    });
  });
}
