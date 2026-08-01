import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/e2ee/identity_label_map.dart';
import 'package:keepsy/e2ee/prekey_api.dart';
import 'package:keepsy/e2ee/prekey_bundle.dart';

import '../_sodium_setup.dart';
import '../secure_store/mock_secure_key_store.dart';
import 'identity_label_map_test_helpers.dart';

class _StubPrekeyApi implements PrekeyApi {
  Map<String, dynamic>? lastUpsert;
  Map<String, dynamic>? lastRotate;
  final List<List<PrekeyOpk>> replenishBatches = [];
  final List<Uint8List> replenishSigs = [];
  int countResponse = 20;
  int rotateCalls = 0;
  int countCalls = 0;
  int upsertCalls = 0;
  // Programmable errors. If set, the next matching call throws and clears
  PrekeyApiException? upsertError;
  PrekeyApiException? replenishError;

  @override
  Future<int> opkCount() async {
    countCalls++;
    return countResponse;
  }

  @override
  Future<OwnKeys> fetchOwnKeys() async => OwnKeys(
      ikPub: Uint8List(0),
      lkPub: Uint8List(0),
      spkPub: Uint8List(0),
      spkTs: null);

  @override
  Future<void> replenishOpks(
      {required List<PrekeyOpk> opks, required Uint8List replenishSig}) async {
    if (replenishError != null) {
      final e = replenishError!;
      replenishError = null;
      throw e;
    }
    replenishBatches.add(List.of(opks));
    replenishSigs.add(Uint8List.fromList(replenishSig));
  }

  @override
  Future<void> rotateSpk(
      {required Uint8List spkPub,
      required Uint8List spkSig,
      required int spkTs,
      required Uint8List rotationSig}) async {
    rotateCalls++;
    lastRotate = {
      'spk_pub': Uint8List.fromList(spkPub),
      'spk_sig': Uint8List.fromList(spkSig),
      'spk_ts': spkTs,
      'rotation_sig': Uint8List.fromList(rotationSig),
    };
  }

  @override
  Future<void> upsertIdentity(
      {required Uint8List ikPub,
      required Uint8List lkPub,
      required Uint8List spkPub,
      required Uint8List spkSig,
      required int spkTs}) async {
    upsertCalls++;
    if (upsertError != null) {
      final e = upsertError!;
      upsertError = null;
      throw e;
    }
    lastUpsert = {
      'ik_pub': Uint8List.fromList(ikPub),
      'lk_pub': Uint8List.fromList(lkPub),
      'spk_pub': Uint8List.fromList(spkPub),
      'spk_sig': Uint8List.fromList(spkSig),
      'spk_ts': spkTs,
    };
  }

  @override
  Future<PrekeyBundle> fetchPrekeyBundleByHandle(String handle) =>
      throw UnimplementedError();

  @override
  Future<PrekeyBundle> fetchPrekeyBundle(String userId) async {
    throw UnimplementedError('fetchPrekeyBundle not used by IdentityService');
  }
}

Future<
    ({
      IdentityService svc,
      MockSecureKeyStore store,
      IdentityLabelMap labels,
      _StubPrekeyApi api
    })> _newService({DateTime? now}) async {
  final store = MockSecureKeyStore();
  await store.initialize();
  final labels = makeInMemoryLabelMap();
  await labels.load();
  final api = _StubPrekeyApi();
  final svc = IdentityService(
    store: store,
    labels: labels,
    api: api,
    now: now == null ? DateTime.now : () => now,
  );
  return (svc: svc, store: store, labels: labels, api: api);
}

void main() {
  setUpAll(ensureSodium);

  group('IdentityService', () {
    test(
        'bootstrap creates kBootstrapOpkPool OPKs and uploads a valid '
        'replenish_sig', () async {
      final fixed = DateTime.utc(2026, 5, 4, 12);
      final r = await _newService(now: fixed);

      await r.svc.bootstrap();

      // Bootstrap pool labels in the map : background replenish lifts to target
      final opkLabels = r.labels.labelsWithPrefix(kLabelOpkPrefix);
      expect(opkLabels.length, kBootstrapOpkPool);
      // IK / LK / SPK current persisted
      expect(r.labels.handleId(kLabelIK), isNotNull);
      expect(r.labels.handleId(kLabelLK), isNotNull);
      expect(r.labels.handleId(kLabelSpkCurrent), isNotNull);

      // /keys uploaded with the correct shapes
      final upsert = r.api.lastUpsert!;
      expect((upsert['ik_pub'] as Uint8List).length, 32);
      expect((upsert['spk_sig'] as Uint8List).length, 64);
      expect(upsert['spk_ts'], fixed.millisecondsSinceEpoch ~/ 1000);

      // /opks : one bootstrap batch
      expect(r.api.replenishBatches.length, 1);
      final batch = r.api.replenishBatches.first;
      expect(batch.length, kBootstrapOpkPool);
      // idx is 0..kBootstrapOpkPool-1 in array order
      for (var i = 0; i < kBootstrapOpkPool; i++) {
        expect(batch[i].idx, i);
        expect(batch[i].keyPub.length, 32);
      }

      // replenish_sig verifies under ik_pub for the §6.5 message
      final ikPub = upsert['ik_pub'] as Uint8List;
      final msg = await _replenishMsgForTest(batch);
      final ok = await Sign.verify(ikPub, msg, r.api.replenishSigs.first);
      expect(ok, isTrue);
    });

    test('ensureSpkRotated is idempotent within the 30d window', () async {
      // bootstrap at t0 : ensureSpkRotated at t0+1d : no /spk call
      final t0 = DateTime.utc(2026, 5, 4, 12);
      var clockNow = t0;
      final store = MockSecureKeyStore();
      await store.initialize();
      final labels = makeInMemoryLabelMap();
      await labels.load();
      final api = _StubPrekeyApi();
      final svc = IdentityService(
        store: store,
        labels: labels,
        api: api,
        now: () => clockNow,
      );
      await svc.bootstrap();

      clockNow = t0.add(const Duration(days: 1));
      await svc.ensureSpkRotated();
      await svc.ensureSpkRotated();

      expect(api.rotateCalls, 0);
    });

    test('ensureSpkRotated rotates after 30d with a verifiable rotation_sig',
        () async {
      final t0 = DateTime.utc(2026, 5, 4, 12);
      var clockNow = t0;
      final store = MockSecureKeyStore();
      await store.initialize();
      final labels = makeInMemoryLabelMap();
      await labels.load();
      final api = _StubPrekeyApi();
      final svc = IdentityService(
        store: store,
        labels: labels,
        api: api,
        now: () => clockNow,
      );
      await svc.bootstrap();

      clockNow = t0.add(const Duration(days: 31));
      await svc.ensureSpkRotated();

      expect(api.rotateCalls, 1);
      final rot = api.lastRotate!;
      final newSpkPub = rot['spk_pub'] as Uint8List;
      final newSpkTs = rot['spk_ts'] as int;
      final rotationSig = rot['rotation_sig'] as Uint8List;
      final spkSig = rot['spk_sig'] as Uint8List;
      expect(newSpkTs, clockNow.millisecondsSinceEpoch ~/ 1000);

      final ikPub = api.lastUpsert!['ik_pub'] as Uint8List;

      // spk_sig over spk_pub || u64_be(ts)
      final spkSigMsg = Uint8List(40);
      spkSigMsg.setRange(0, 32, newSpkPub);
      ByteData.sublistView(spkSigMsg, 32).setUint64(0, newSpkTs, Endian.big);
      expect(await Sign.verify(ikPub, spkSigMsg, spkSig), isTrue);

      // rotation_sig over "rotate-spk-v1" || spk_pub || u64_be(ts)
      final salt = kSaltSpkRotate;
      final rotMsg = Uint8List(salt.length + 32 + 8);
      rotMsg.setRange(0, salt.length, salt);
      rotMsg.setRange(salt.length, salt.length + 32, newSpkPub);
      ByteData.sublistView(rotMsg, salt.length + 32)
          .setUint64(0, newSpkTs, Endian.big);
      expect(await Sign.verify(ikPub, rotMsg, rotationSig), isTrue);
    });

    test('replenish raises pool to target when count < trigger', () async {
      final fixed = DateTime.utc(2026, 5, 4, 12);
      final r = await _newService(now: fixed);
      await r.svc.bootstrap();
      // After bootstrap : one initial batch recorded. Reset and lower the count
      r.api.replenishBatches.clear();
      r.api.replenishSigs.clear();
      r.api.countResponse = 4;

      await r.svc.replenishOpks();

      expect(r.api.countCalls, 1);
      expect(r.api.replenishBatches.length, 1);
      // target - count = (20 - 4) = 16 fresh keys
      final needed = kTargetOpkPool - 4;
      expect(r.api.replenishBatches.first.length, needed);
      // New idxs start above (kBootstrapOpkPool - 1) = 4. First new idx = 5
      expect(r.api.replenishBatches.first.first.idx, kBootstrapOpkPool);
      expect(r.api.replenishBatches.first.last.idx,
          kBootstrapOpkPool + needed - 1);
      // Label map total = bootstrap + replenish
      expect(r.labels.labelsWithPrefix(kLabelOpkPrefix).length,
          kBootstrapOpkPool + needed);
    });

    // §7 + new bootstrap resume behavior : when /keys returns 409, bootstrap
    // must surface a typed conflict instead of bouncing the user back to a
    // generic "Invalid OTP" loop
    test('bootstrap throws BootstrapAccountConflictException on 409 from /keys',
        () async {
      final r = await _newService(now: DateTime.utc(2026, 5, 4, 12));
      r.api.upsertError = const PrekeyApiException(
        code: 'E_IDENTITY_ALREADY_SET',
        message: 'identity already published',
        httpStatus: 409,
      );

      await expectLater(
        r.svc.bootstrap(),
        throwsA(isA<BootstrapAccountConflictException>()),
      );

      // No publish flags should have been flipped : the conflict means the
      // local IK is unusable, retry must keep the same outcome until the
      // user clears state out of band
      expect(await r.labels.isIdentityPublished(), isFalse);
      expect(await r.labels.areInitialOpksPublished(), isFalse);
    });

    // Resume: if /keys succeeded but /opks failed (network blip between the
    // two calls), bootstrap on next launch must NOT regenerate keys or call
    // /keys again. It should re-use the persisted privs and only retry /opks
    test(
        'bootstrap resumes from a failed initial OPK upload without re-publishing identity',
        () async {
      final r = await _newService(now: DateTime.utc(2026, 5, 4, 12));
      r.api.replenishError = const PrekeyApiException(
        code: 'E_INTERNAL',
        message: 'transient',
        httpStatus: 500,
      );

      await expectLater(r.svc.bootstrap(), throwsA(isA<PrekeyApiException>()));

      // After the failure: identity is published, OPKs are not, labels are
      // already in place from per-key persistence
      expect(await r.labels.isIdentityPublished(), isTrue);
      expect(await r.labels.areInitialOpksPublished(), isFalse);
      expect(r.api.upsertCalls, 1);
      expect(r.labels.handleId(kLabelIK), isNotNull);
      expect(
          r.labels.labelsWithPrefix(kLabelOpkPrefix).length, kBootstrapOpkPool);

      // Second attempt: only /opks should be retried; /keys must NOT be
      // called again (server would 409 and we'd surface conflict spuriously)
      await r.svc.bootstrap();

      expect(r.api.upsertCalls, 1, reason: '/keys must not be called twice');
      expect(r.api.replenishBatches.length, 1);
      expect(r.api.replenishBatches.first.length, kBootstrapOpkPool);
      expect(await r.labels.areInitialOpksPublished(), isTrue);
      expect(await r.svc.isBootstrapped(), isTrue);
    });

    // isBootstrapped guards on full publish state, not just local labels
    test('isBootstrapped reflects full publish state', () async {
      final r = await _newService(now: DateTime.utc(2026, 5, 4, 12));
      expect(await r.svc.isBootstrapped(), isFalse);
      await r.svc.bootstrap();
      expect(await r.svc.isBootstrapped(), isTrue);
    });

    // the safety number needs OUR ik_pub. It must be derived from the
    // seed we hold, never read back from the server (a lying server would
    // otherwise pick both sides of the comparison)
    test('currentIkPub derives the same ik_pub that bootstrap published',
        () async {
      final r = await _newService(now: DateTime.utc(2026, 5, 4, 12));
      await r.svc.bootstrap();

      final ik = await r.svc.currentIkPub();

      expect(ik.length, 32);
      expect(ik, r.api.lastUpsert!['ik_pub'] as Uint8List);
    });

    test('currentIkPub caches : repeat calls dont re read the keystore',
        () async {
      final r = await _newService(now: DateTime.utc(2026, 5, 4, 12));
      await r.svc.bootstrap();

      await r.svc.currentIkPub();
      final after = r.store.getOnceCalls;
      await r.svc.currentIkPub();
      await r.svc.currentIkPub();

      expect(r.store.getOnceCalls, after,
          reason: 'ik_pub is public and immutable : derive it once');
    });

    test('currentIkPub throws before bootstrap', () async {
      final r = await _newService();
      expect(r.svc.currentIkPub, throwsStateError);
    });
  });
}

// Mirror of IdentityService's private _replenishMsg, exposed only for test
// re verification of the in memory replenish_sig
Future<Uint8List> _replenishMsgForTest(List<PrekeyOpk> opks) async {
  final concat = Uint8List(32 * opks.length);
  for (var i = 0; i < opks.length; i++) {
    concat.setRange(i * 32, (i + 1) * 32, opks[i].keyPub);
  }
  final digest = await cg.Sha256().hash(concat);
  final salt = Uint8List.fromList('opk-batch-v1'.codeUnits);
  final out = Uint8List(salt.length + 4 + digest.bytes.length);
  out.setRange(0, salt.length, salt);
  ByteData.sublistView(out, salt.length, salt.length + 4)
      .setUint32(0, opks.length, Endian.big);
  out.setRange(salt.length + 4, out.length, digest.bytes);
  return out;
}
