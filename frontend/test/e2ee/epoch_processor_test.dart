import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/epoch_api.dart';
import 'package:keepsy/e2ee/epoch_processor.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/e2ee/member_directory.dart';
import 'package:keepsy/e2ee/prekey_api.dart';
import 'package:keepsy/e2ee/wrap_envelope.dart';
import 'package:keepsy/secure_store/key_handle_adapter.dart';

import '../_sodium_setup.dart';
import '_admin_test_helpers.dart';

Uint8List _albumId([int seed = 0xA1]) =>
    Uint8List.fromList(List<int>.filled(16, seed));

Uint8List _mk(int b) => Uint8List.fromList(List<int>.filled(32, b));

// Helper : seeds an entire processor stack against one album. Returns the
// pieces tests want to poke (api, store, processor, admin) so each test can
// stay tight
class _Stack {
  final FakeEpochApi api;
  final AlbumKeyStore aks;
  final EpochProcessor processor;
  final SyntheticAdmin admin;
  final dynamic responder;
  final Uint8List albumId;
  final String albumIdStr;
  _Stack({
    required this.api,
    required this.aks,
    required this.processor,
    required this.admin,
    required this.responder,
    required this.albumId,
    required this.albumIdStr,
  });
}

Future<_Stack> _bootStack({
  Uint8List? albumId,
  Duration? backoff,
  DateTime Function()? nowFn,
}) async {
  final id = albumId ?? _albumId();
  final responder = await newResponderIdentity(nowFn: nowFn);
  final admin = await SyntheticAdmin.create();
  final directory = MemberDirectory(singletonAdminFetcher(admin));
  final api = FakeEpochApi();
  final aks = AlbumKeyStore(responder.store);
  await aks.initialize();
  final processor = EpochProcessor(
    api: api,
    identity: responder.svc,
    store: aks,
    directory: directory,
    backoff: backoff == null ? null : (_) => backoff,
  );
  return _Stack(
    api: api,
    aks: aks,
    processor: processor,
    admin: admin,
    responder: responder,
    albumId: id,
    albumIdStr: uuidStringFromBytes(id),
  );
}

const int _spkTs = 1714838400; // anchored, well within ±90d skew

void main() {
  setUpAll(ensureSodium);

  group('EpochProcessor.handleEvent', () {
    test('round trip: synthetic admin builds wrap, processor installs MK',
        () async {
      final s = await _bootStack();
      final mk = _mk(0xCC);
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      final env = await s.admin.buildWrap(
        albumId: s.albumId,
        epoch: 0,
        mk: mk,
        responderBundle: bundle,
      );
      s.api.putWrap(s.albumIdStr, 0, env);

      await s.processor.handleEvent(albumId: s.albumId, epoch: 0);

      expect(await s.aks.presentEpochs(s.albumId), [0]);
      // installed MK round trips through useMk
      final got = await s.aks
          .useMk<List<int>>(s.albumId, 0, (b) async => List<int>.from(b));
      expect(got, equals(mk));
    });

    test('concurrent events for two albums install both without crosstalk',
        () async {
      // Two stacks share a single FakeEpochApi + MemberDirectory but each
      // keeps their own SecureKeyStore + IdentityService since the responder
      // identity is per device. Run handleEvent in parallel : both must land
      final api = FakeEpochApi();
      final adminA = await SyntheticAdmin.create();
      final adminB = await SyntheticAdmin.create();
      final dirA = MemberDirectory(singletonAdminFetcher(adminA));
      final dirB = MemberDirectory(singletonAdminFetcher(adminB));
      final respA = await newResponderIdentity();
      final respB = await newResponderIdentity();
      final aksA = AlbumKeyStore(respA.store);
      final aksB = AlbumKeyStore(respB.store);
      await aksA.initialize();
      await aksB.initialize();
      final pA = EpochProcessor(
        api: api,
        identity: respA.svc,
        store: aksA,
        directory: dirA,
      );
      final pB = EpochProcessor(
        api: api,
        identity: respB.svc,
        store: aksB,
        directory: dirB,
      );
      final idA = _albumId(0xA1);
      final idB = _albumId(0xB2);
      final mkA = _mk(0xAA);
      final mkB = _mk(0xBB);
      final bundleA =
          await buildResponderBundle(responder: respA.svc, spkTs: _spkTs);
      final bundleB =
          await buildResponderBundle(responder: respB.svc, spkTs: _spkTs);
      api.putWrap(
          uuidStringFromBytes(idA),
          0,
          await adminA.buildWrap(
              albumId: idA, epoch: 0, mk: mkA, responderBundle: bundleA));
      api.putWrap(
          uuidStringFromBytes(idB),
          0,
          await adminB.buildWrap(
              albumId: idB, epoch: 0, mk: mkB, responderBundle: bundleB));

      await Future.wait([
        pA.handleEvent(albumId: idA, epoch: 0),
        pB.handleEvent(albumId: idB, epoch: 0),
      ]);

      final gotA =
          await aksA.useMk<List<int>>(idA, 0, (b) async => List<int>.from(b));
      final gotB =
          await aksB.useMk<List<int>>(idB, 0, (b) async => List<int>.from(b));
      expect(gotA, equals(mkA));
      expect(gotB, equals(mkB));
    });

    test('AAD mismatch (epoch 4 baked into AAD, URL says 5) -> AEAD auth fails',
        () async {
      final s = await _bootStack();
      final mk = _mk(0xDD);
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      // Encrypt with AAD epoch=4 but advertise epoch=5 over the wire (D5 :
      // AEAD AAD binding catches this before installVerified ever runs)
      final env = await s.admin.buildWrap(
        albumId: s.albumId,
        epoch: 5,
        mk: mk,
        responderBundle: bundle,
        aadEpochOverride: 4,
      );
      s.api.putWrap(s.albumIdStr, 5, env);

      await expectLater(
        s.processor.handleEvent(albumId: s.albumId, epoch: 5),
        throwsA(isA<WrapVerificationException>()
            .having((e) => e.reason, 'reason', 'aead_auth_failed')),
      );
      expect(await s.aks.presentEpochs(s.albumId), isEmpty);
    });

    test('wrap missing 404 -> retries with backoff, eventually succeeds',
        () async {
      // backoff overridden to Duration.zero so the test doesnt wait the real
      // 200/800/3200ms ladder
      final s = await _bootStack(backoff: Duration.zero);
      final mk = _mk(0xEE);
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      final env = await s.admin.buildWrap(
        albumId: s.albumId,
        epoch: 2,
        mk: mk,
        responderBundle: bundle,
      );
      // First two fetches return 404 (race), third succeeds
      s.api.putWrap(s.albumIdStr, 2, env);
      s.api.setNotFoundCount(s.albumIdStr, 2, 2);

      await s.processor.handleEvent(albumId: s.albumId, epoch: 2);

      expect(s.api.fetchLog.length, 3,
          reason: 'expected 2 retries before the 3rd hit succeeds');
      expect(await s.aks.presentEpochs(s.albumId), [2]);
    });

    test('cold start catch up: local up to 3, server on 7 -> fetches 4..7',
        () async {
      final s = await _bootStack();
      // Pre install MK_0..MK_3 directly so the processor only chases 4..7
      for (var i = 0; i <= 3; i++) {
        await s.aks.installVerified(
            albumId: s.albumId, epoch: i, mk: _mk(0x10 + i), backfill: false);
      }
      s.api.currents[s.albumIdStr] = EpochCurrent(
        currentEpoch: 7,
        startedAt: DateTime.utc(2026, 5, 7, 12),
      );
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      for (var i = 4; i <= 7; i++) {
        final env = await s.admin.buildWrap(
          albumId: s.albumId,
          epoch: i,
          mk: _mk(0x40 + i),
          responderBundle: bundle,
        );
        s.api.putWrap(s.albumIdStr, i, env);
      }

      await s.processor.catchUpAll([s.albumId]);

      // Fetched in order: 4, 5, 6, 7
      expect(s.api.fetchLog.map((e) => e.epoch).toList(), [4, 5, 6, 7]);
      expect(await s.aks.presentEpochs(s.albumId), [0, 1, 2, 3, 4, 5, 6, 7]);
      expect(await s.aks.latestEpoch(s.albumId), 7);
    });

    test('catchUpAll: failure on album A doesnt block album B', () async {
      // Two responder identities + two album ids share one FakeEpochApi. Album
      // A has currentEpoch=0 but the wrap is missing on every fetch (404
      // exceeds maxRetries) : album B has a valid wrap. catchUpAll must
      // continue past A's failure and install B
      final api = FakeEpochApi();
      final adminB = await SyntheticAdmin.create();
      final dirB = MemberDirectory(singletonAdminFetcher(adminB));
      final resp = await newResponderIdentity();
      final aks = AlbumKeyStore(resp.store);
      await aks.initialize();
      final processor = EpochProcessor(
        api: api,
        identity: resp.svc,
        store: aks,
        directory: dirB,
        backoff: (_) => Duration.zero,
      );

      final idA = _albumId(0xAA);
      final idB = _albumId(0xBB);
      final mkB = _mk(0xBB);
      api.currents[uuidStringFromBytes(idA)] = EpochCurrent(
        currentEpoch: 0,
        startedAt: DateTime.utc(2026, 5, 7, 12),
      );
      api.currents[uuidStringFromBytes(idB)] = EpochCurrent(
        currentEpoch: 0,
        startedAt: DateTime.utc(2026, 5, 7, 12),
      );
      // No putWrap for A -> getWrap throws EpochWrapNotFoundException after
      // maxRetries
      final bundleB =
          await buildResponderBundle(responder: resp.svc, spkTs: _spkTs);
      api.putWrap(
          uuidStringFromBytes(idB),
          0,
          await adminB.buildWrap(
              albumId: idB, epoch: 0, mk: mkB, responderBundle: bundleB));

      await processor.catchUpAll([idA, idB]);

      expect(await aks.presentEpochs(idA), isEmpty,
          reason: "A's wrap was missing : nothing to install");
      expect(await aks.presentEpochs(idB), [0],
          reason: 'B must install even though A failed first');
    });

    test(
        'previous SPK fallback: a wrap built against a rotated-away SPK still '
        'installs', () async {
      // The wrap targets the SPK retained in the previous slot
      var clock = DateTime.utc(2026, 5, 4, 12);
      final s = await _bootStack(nowFn: () => clock);
      final mk = _mk(0x5A);
      // bundle captures SPK1 (current at bootstrap)
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      final env = await s.admin.buildWrap(
        albumId: s.albumId,
        epoch: 0,
        mk: mk,
        responderBundle: bundle,
      );
      s.api.putWrap(s.albumIdStr, 0, env);
      // rotate : SPK1 -> previous slot, fresh SPK2 -> current
      clock = clock.add(const Duration(days: 31));
      await s.responder.svc.ensureSpkRotated();

      await s.processor.handleEvent(albumId: s.albumId, epoch: 0);

      expect(await s.aks.presentEpochs(s.albumId), [0]);
      final got = await s.aks
          .useMk<List<int>>(s.albumId, 0, (b) async => List<int>.from(b));
      expect(got, equals(mk));
    });

    test(
        'pending SPK: a wrap built against a rotation the server accepted but '
        'we never got the response for installs WITHOUT any reconciliation',
        () async {
      // Delivery must work before network reconciliation can run
      var clock = DateTime.utc(2026, 5, 4, 12);
      final s = await _bootStack(nowFn: () => clock);
      final mk = _mk(0x6C);

      clock = clock.add(const Duration(days: 31));
      s.responder.api.rotateError = const PrekeyApiException(
          code: 'E_INTERNAL', message: 'dropped', httpStatus: 500);
      await expectLater(s.responder.svc.ensureSpkRotated(),
          throwsA(isA<PrekeyApiException>()));
      final callsAfterRotate = s.responder.api.fetchOwnKeysCalls as int;

      // Peers receive the pending key after the server accepts the rotation
      final bundle = await buildResponderBundle(
          responder: s.responder.svc, spkTs: _spkTs, slot: SpkSlot.pending);
      final env = await s.admin.buildWrap(
        albumId: s.albumId,
        epoch: 0,
        mk: mk,
        responderBundle: bundle,
      );
      s.api.putWrap(s.albumIdStr, 0, env);

      await s.processor.handleEvent(albumId: s.albumId, epoch: 0);

      expect(await s.aks.presentEpochs(s.albumId), [0]);
      final got = await s.aks
          .useMk<List<int>>(s.albumId, 0, (b) async => List<int>.from(b));
      expect(got, equals(mk));
      expect(s.responder.api.fetchOwnKeysCalls, callsAfterRotate,
          reason: 'the unwrap path must not need a network round trip');
    });

    test(
        'previous SPK fallback still works while a pending rotation is '
        'unsettled', () async {
      // Pending must not shadow the previous fallback
      var clock = DateTime.utc(2026, 5, 4, 12);
      final s = await _bootStack(nowFn: () => clock);
      final mk = _mk(0x6D);
      // wrap captures SPK1 while it is still current
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      final env = await s.admin.buildWrap(
        albumId: s.albumId,
        epoch: 0,
        mk: mk,
        responderBundle: bundle,
      );
      s.api.putWrap(s.albumIdStr, 0, env);

      // Clean rotation: SPK1 -> previous, SPK2 -> current
      clock = clock.add(const Duration(days: 31));
      await s.responder.svc.ensureSpkRotated();
      // A lost response leaves SPK3 pending
      clock = clock.add(const Duration(days: 31));
      s.responder.api.rotateError = const PrekeyApiException(
          code: 'E_INTERNAL', message: 'dropped', httpStatus: 500);
      await expectLater(s.responder.svc.ensureSpkRotated(),
          throwsA(isA<PrekeyApiException>()));

      await s.processor.handleEvent(albumId: s.albumId, epoch: 0);

      expect(await s.aks.presentEpochs(s.albumId), [0]);
      final got = await s.aks
          .useMk<List<int>>(s.albumId, 0, (b) async => List<int>.from(b));
      expect(got, equals(mk));
    });

    test(
        'archived SPK: a wrap built against a key that was briefly advertised '
        'before an unknown SPK superseded it still installs', () async {
      var clock = DateTime.utc(2026, 5, 4, 12);
      final s = await _bootStack(nowFn: () => clock);
      final mk = _mk(0x7E);

      clock = clock.add(const Duration(days: 31));
      s.responder.api.rotateError = const PrekeyApiException(
          code: 'E_INTERNAL', message: 'dropped', httpStatus: 500);
      await expectLater(s.responder.svc.ensureSpkRotated(),
          throwsA(isA<PrekeyApiException>()));

      // Build the wrap while the pending key is advertised
      final bundle = await buildResponderBundle(
          responder: s.responder.svc, spkTs: _spkTs, slot: SpkSlot.pending);
      final env = await s.admin.buildWrap(
        albumId: s.albumId,
        epoch: 0,
        mk: mk,
        responderBundle: bundle,
      );
      s.api.putWrap(s.albumIdStr, 0, env);

      // An unknown server SPK moves pending to the archive
      final myIk = await s.responder.svc.currentIkPub();
      final myLk = await s.responder.svc.useLk<Uint8List>(
          (p) async => (await KeyHandleAdapter.toX25519(p)).publicKey);
      s.responder.api.own = OwnKeys(
          ikPub: myIk,
          lkPub: myLk,
          spkPub: Uint8List(32)..fillRange(0, 32, 0x5A),
          spkTs: clock.toUtc().millisecondsSinceEpoch ~/ 1000);
      await expectLater(s.responder.svc.reconcilePendingSpk(),
          throwsA(isA<SpkReconciliationConflict>()));

      await s.processor.handleEvent(albumId: s.albumId, epoch: 0);

      expect(await s.aks.presentEpochs(s.albumId), [0]);
      final got = await s.aks
          .useMk<List<int>>(s.albumId, 0, (b) async => List<int>.from(b));
      expect(got, equals(mk));
    });

    test('previous SPK fallback is bounded to one generation back', () async {
      // a wrap built against SPK1, then TWO rotations : SPK1 is now neither
      // current nor previous. The fallback must NOT reach it : still fails
      var clock = DateTime.utc(2026, 5, 4, 12);
      final s = await _bootStack(nowFn: () => clock);
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      final env = await s.admin.buildWrap(
        albumId: s.albumId,
        epoch: 0,
        mk: _mk(0x5B),
        responderBundle: bundle,
      );
      s.api.putWrap(s.albumIdStr, 0, env);
      clock = clock.add(const Duration(days: 31));
      await s.responder.svc.ensureSpkRotated(); // SPK1 -> previous
      clock = clock.add(const Duration(days: 31));
      await s.responder.svc
          .ensureSpkRotated(); // SPK1 evicted, SPK2 -> previous

      await expectLater(
        s.processor.handleEvent(albumId: s.albumId, epoch: 0),
        throwsA(isA<WrapVerificationException>()
            .having((e) => e.reason, 'reason', 'aead_auth_failed')),
      );
      expect(await s.aks.presentEpochs(s.albumId), isEmpty);
    });

    test('sender_sig invalid -> WrapVerificationException(sig_invalid)',
        () async {
      final s = await _bootStack();
      final mk = _mk(0x77);
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      final env = await s.admin.buildWrap(
        albumId: s.albumId,
        epoch: 0,
        mk: mk,
        responderBundle: bundle,
      );
      // Tamper sender_sig : flip a byte : signature must fail to verify
      final bad = Uint8List.fromList(env.senderSig);
      bad[0] ^= 0xFF;
      final tampered = WrapEnvelope(
        epoch: env.epoch,
        ekPub: env.ekPub,
        wrap: env.wrap,
        senderToken: env.senderToken,
        senderSig: bad,
        opkIdxUsed: env.opkIdxUsed,
        deliveredAt: env.deliveredAt,
      );
      s.api.putWrap(s.albumIdStr, 0, tampered);

      await expectLater(
        s.processor.handleEvent(albumId: s.albumId, epoch: 0),
        throwsA(isA<WrapVerificationException>()
            .having((e) => e.reason, 'reason', 'sig_invalid')),
      );
      expect(await s.aks.presentEpochs(s.albumId), isEmpty);
    });
  });
}
