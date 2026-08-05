import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/epoch_api.dart';
import 'package:keepsy/e2ee/epoch_processor.dart';
import 'package:keepsy/e2ee/expected_ik_resolver.dart';
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
  // Signer bindings read and written by the processor gate
  final Map<String, Uint8List> pins;
  final Map<String, Uint8List> rosterPins;
  final List<bool> creating;
  // Single slot box so a test can declare a token "mine" after the stack (and
  // therefore its admin) exists
  final List<Uint8List?> selfBox;
  _Stack({
    required this.api,
    required this.aks,
    required this.processor,
    required this.admin,
    required this.responder,
    required this.albumId,
    required this.albumIdStr,
    required this.pins,
    required this.rosterPins,
    required this.creating,
    required this.selfBox,
  });
}

String _hex(Uint8List b) => b.map((x) => x.toRadixString(16)).join();

Future<_Stack> _bootStack({
  Uint8List? albumId,
  Duration? backoff,
  DateTime Function()? nowFn,
  bool pinAdmin = false,
}) async {
  final id = albumId ?? _albumId();
  final responder = await newResponderIdentity(nowFn: nowFn);
  final admin = await SyntheticAdmin.create();
  final directory = MemberDirectory(singletonAdminFetcher(admin));
  final api = FakeEpochApi();
  final aks = AlbumKeyStore(responder.store);
  await aks.initialize();
  final pins = <String, Uint8List>{}; // signer bindings
  final rosterPins = <String, Uint8List>{}; // what reconcile() writes
  final selfBox = <Uint8List?>[null];
  final creating = <bool>[false];
  final resolver = ExpectedIkResolver.responder(
    selfToken: (_) => selfBox.first,
    pinned: (_, token) => rosterPins[_hex(token)],
    signerPinned: (_, token) => pins[_hex(token)],
    currentIk: responder.svc.currentIkPub,
    soleSigner: (_) => creating.first,
    pin: (_, token, ik) async => pins[_hex(token)] = ik,
  );
  if (pinAdmin) pins[_hex(admin.senderToken)] = admin.ikPub;
  final processor = EpochProcessor(
    api: api,
    identity: responder.svc,
    store: aks,
    directory: directory,
    signerGate: resolver,
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
    pins: pins,
    rosterPins: rosterPins,
    creating: creating,
    selfBox: selfBox,
  );
}

// Counts roster fetches and serves whatever the box currently holds, so a test
// can prove a retry actually re read the roster instead of a stale cache entry
class _MutableRoster {
  final List<MemberRecord> records;
  int fetches = 0;
  _MutableRoster(this.records);
  MemberFetcher get fetcher => (Uint8List _) async {
        fetches++;
        return records;
      };
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
        signerGate: tofuGate(),
      );
      final pB = EpochProcessor(
        api: api,
        identity: respB.svc,
        store: aksB,
        directory: dirB,
        signerGate: tofuGate(),
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
      final s = await _bootStack(pinAdmin: true);
      final mk = _mk(0xDD);
      // 0..4 already held so the contiguous walk reaches straight for 5
      for (var i = 0; i <= 4; i++) {
        await s.aks.installVerified(
            albumId: s.albumId, epoch: i, mk: _mk(0x10 + i), backfill: false);
      }
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
      expect(await s.aks.presentEpochs(s.albumId), [0, 1, 2, 3, 4]);
    });

    test('wrap missing 404 -> retries with backoff, eventually succeeds',
        () async {
      // backoff overridden to Duration.zero so the test doesnt wait the real
      // 200/800/3200ms ladder
      final s = await _bootStack(backoff: Duration.zero, pinAdmin: true);
      final mk = _mk(0xEE);
      for (var i = 0; i <= 1; i++) {
        await s.aks.installVerified(
            albumId: s.albumId, epoch: i, mk: _mk(0x10 + i), backfill: false);
      }
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
      expect(await s.aks.presentEpochs(s.albumId), [0, 1, 2]);
    });

    test('cold start catch up: local up to 3, server on 7 -> fetches 4..7',
        () async {
      final s = await _bootStack(pinAdmin: true);
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
        signerGate: tofuGate(),
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

    test('a live event that skips an epoch installs the gap in order',
        () async {
      // Two rotations can fan out independently, so 5 may arrive before 4. The
      // old latestEpoch cursor would have stranded 4 permanently
      final s = await _bootStack(pinAdmin: true);
      for (var i = 0; i <= 3; i++) {
        await s.aks.installVerified(
            albumId: s.albumId, epoch: i, mk: _mk(0x10 + i), backfill: false);
      }
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      for (var i = 4; i <= 5; i++) {
        s.api.putWrap(
            s.albumIdStr,
            i,
            await s.admin.buildWrap(
                albumId: s.albumId,
                epoch: i,
                mk: _mk(0x40 + i),
                responderBundle: bundle));
      }

      await s.processor.handleEvent(albumId: s.albumId, epoch: 5);

      expect(s.api.fetchLog.map((e) => e.epoch).toList(), [4, 5]);
      expect(await s.aks.presentEpochs(s.albumId), [0, 1, 2, 3, 4, 5]);
    });

    test('a live event whose gap cannot be filled installs nothing', () async {
      // Blocking is the point: installing 5 while 4 is unfetchable would make
      // every photo sealed under MK_4 permanently undecryptable
      final s = await _bootStack(backoff: Duration.zero, pinAdmin: true);
      await s.aks.installVerified(
          albumId: s.albumId, epoch: 0, mk: _mk(0x10), backfill: false);
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      // epoch 1 is never published: only 2 is available
      s.api.putWrap(
          s.albumIdStr,
          2,
          await s.admin.buildWrap(
              albumId: s.albumId,
              epoch: 2,
              mk: _mk(0x42),
              responderBundle: bundle));

      await expectLater(
        s.processor.handleEvent(albumId: s.albumId, epoch: 2),
        throwsA(isA<EpochWrapNotFoundException>()),
      );
      expect(await s.aks.presentEpochs(s.albumId), [0],
          reason: 'epoch 2 must not install ahead of the missing epoch 1');
    });

    test('a hole left by an earlier install is repaired on the next event',
        () async {
      // Devices from the cursor-only build may already contain gaps, so the
      // contiguous handler must inspect actual stored epochs
      final s = await _bootStack(pinAdmin: true);
      await s.aks.installVerified(
          albumId: s.albumId, epoch: 0, mk: _mk(0x10), backfill: false);
      await s.aks.installVerified(
          albumId: s.albumId, epoch: 2, mk: _mk(0x12), backfill: false);
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      for (final i in [1, 3]) {
        s.api.putWrap(
            s.albumIdStr,
            i,
            await s.admin.buildWrap(
                albumId: s.albumId,
                epoch: i,
                mk: _mk(0x40 + i),
                responderBundle: bundle));
      }

      await s.processor.handleEvent(albumId: s.albumId, epoch: 3);

      expect(s.api.fetchLog.map((e) => e.epoch).toList(), [1, 3]);
      expect(await s.aks.presentEpochs(s.albumId), [0, 1, 2, 3]);
    });

    test('a first sight signer key becomes the TOFU baseline', () async {
      final s = await _bootStack();
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      s.api.putWrap(
          s.albumIdStr,
          0,
          await s.admin.buildWrap(
              albumId: s.albumId,
              epoch: 0,
              mk: _mk(0xCC),
              responderBundle: bundle));

      await s.processor.handleEvent(albumId: s.albumId, epoch: 0);

      expect(await s.aks.presentEpochs(s.albumId), [0]);
      expect(s.pins[_hex(s.admin.senderToken)], equals(s.admin.ikPub),
          reason: 'the baseline every later transition is checked against : it '
              'does not defend this first one, which is plain TOFU');
    });

    test('a signer key contradicting the pin is refused and installs nothing',
        () async {
      // The substitution attack: roster hands us an attacker IK/LK for the
      // admin's token, so the server can derive the X3DH secret and sign a wrap
      // carrying an MK it knows
      final s = await _bootStack();
      s.pins[_hex(s.admin.senderToken)] =
          Uint8List.fromList(List<int>.filled(32, 0x5E));
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      s.api.putWrap(
          s.albumIdStr,
          0,
          await s.admin.buildWrap(
              albumId: s.albumId,
              epoch: 0,
              mk: _mk(0xCC),
              responderBundle: bundle));

      await expectLater(
        s.processor.handleEvent(albumId: s.albumId, epoch: 0),
        throwsA(isA<IdentitySignerMismatchException>()),
      );
      expect(await s.aks.presentEpochs(s.albumId), isEmpty);
    });

    test('verifying the presented key out of band unblocks the install',
        () async {
      // markVerified moves the signer binding; only the successful retry clears
      // the block
      final s = await _bootStack();
      s.pins[_hex(s.admin.senderToken)] =
          Uint8List.fromList(List<int>.filled(32, 0x5E));
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      s.api.putWrap(
          s.albumIdStr,
          0,
          await s.admin.buildWrap(
              albumId: s.albumId,
              epoch: 0,
              mk: _mk(0xCC),
              responderBundle: bundle));
      await expectLater(s.processor.handleEvent(albumId: s.albumId, epoch: 0),
          throwsA(isA<IdentitySignerMismatchException>()));

      s.pins[_hex(s.admin.senderToken)] = s.admin.ikPub; // markVerified

      await s.processor.handleEvent(albumId: s.albumId, epoch: 0);

      expect(await s.aks.presentEpochs(s.albumId), [0]);
    });

    test('an unknown signer is refused once the album has keys', () async {
      // No signer binding exists for this token, but the album already has MKs.
      final s = await _bootStack();
      await s.aks.installVerified(
          albumId: s.albumId, epoch: 0, mk: _mk(0x10), backfill: false);
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      s.api.putWrap(
          s.albumIdStr,
          1,
          await s.admin.buildWrap(
              albumId: s.albumId,
              epoch: 1,
              mk: _mk(0xCC),
              responderBundle: bundle));

      await expectLater(s.processor.handleEvent(albumId: s.albumId, epoch: 1),
          throwsA(isA<UnknownSignerException>()));
      expect(s.pins, isEmpty);
      expect(await s.aks.presentEpochs(s.albumId), [0]);
    });

    test('a bad signature cannot poison the first sight pin', () async {
      // check() precedes signature verification, so it must not persist signer
      // authority yet
      final s = await _bootStack();
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      final env = await s.admin.buildWrap(
          albumId: s.albumId, epoch: 0, mk: _mk(0xCC), responderBundle: bundle);
      final bad = Uint8List.fromList(env.senderSig);
      bad[0] ^= 0xFF;
      s.api.putWrap(
          s.albumIdStr,
          0,
          WrapEnvelope(
            epoch: env.epoch,
            ekPub: env.ekPub,
            wrap: env.wrap,
            senderToken: env.senderToken,
            senderSig: bad,
            opkIdxUsed: env.opkIdxUsed,
            deliveredAt: env.deliveredAt,
          ));

      await expectLater(s.processor.handleEvent(albumId: s.albumId, epoch: 0),
          throwsA(isA<WrapVerificationException>()));

      expect(s.pins, isEmpty,
          reason: 'a server with no private key must not move our baseline');
    });

    test('a wrap attributed to our own token must carry our own IK', () async {
      // No user override exists for this one : the device already holds its own
      // key, so a mismatch is the server lying about us
      final s = await _bootStack();
      // the wrap arrives attributed to OUR token, but carries the admin's IK
      s.selfBox[0] = s.admin.senderToken;
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      s.api.putWrap(
          s.albumIdStr,
          0,
          await s.admin.buildWrap(
              albumId: s.albumId,
              epoch: 0,
              mk: _mk(0xCC),
              responderBundle: bundle));

      await expectLater(
        s.processor.handleEvent(albumId: s.albumId, epoch: 0),
        throwsA(isA<IdentitySignerMismatchException>()
            .having((e) => e.isSelf, 'isSelf', isTrue)),
      );
      expect(s.pins, isEmpty, reason: 'the self path never pins');
    });

    test('a refused install reports the album blocked with the presented key',
        () async {
      // Both catchUpAll and the WS dispatch swallow throws, so without this the
      // album just stops taking new photos with nothing said to anyone
      final s = await _bootStack();
      s.pins[_hex(s.admin.senderToken)] =
          Uint8List.fromList(List<int>.filled(32, 0x5E));
      final events = <EpochBlocked>[];
      s.processor.blocked.listen(events.add);
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      s.api.putWrap(
          s.albumIdStr,
          0,
          await s.admin.buildWrap(
              albumId: s.albumId,
              epoch: 0,
              mk: _mk(0xCC),
              responderBundle: bundle));

      await expectLater(s.processor.handleEvent(albumId: s.albumId, epoch: 0),
          throwsA(isA<IdentitySignerMismatchException>()));
      await pumpEventQueue();

      expect(events, hasLength(1));
      expect(events.single.reason, EpochBlockReason.signerMismatch);
      expect(events.single.epoch, 0);
      expect(events.single.senderToken, equals(s.admin.senderToken));
      // the sheet must show THIS key, not one re-fetched from the roster later
      expect(events.single.presentedIk, equals(s.admin.ikPub));
    });

    test('a wrap our own token cannot own is reported as a self mismatch',
        () async {
      final s = await _bootStack();
      s.selfBox[0] = s.admin.senderToken;
      final events = <EpochBlocked>[];
      s.processor.blocked.listen(events.add);
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      s.api.putWrap(
          s.albumIdStr,
          0,
          await s.admin.buildWrap(
              albumId: s.albumId,
              epoch: 0,
              mk: _mk(0xCC),
              responderBundle: bundle));

      await expectLater(s.processor.handleEvent(albumId: s.albumId, epoch: 0),
          throwsA(isA<IdentitySignerMismatchException>()));
      await pumpEventQueue();

      expect(events.single.reason, EpochBlockReason.selfSignerMismatch);
    });

    test('an unfetchable wrap reports the album blocked as unavailable',
        () async {
      final s = await _bootStack(backoff: Duration.zero);
      final events = <EpochBlocked>[];
      s.processor.blocked.listen(events.add);

      await expectLater(s.processor.handleEvent(albumId: s.albumId, epoch: 0),
          throwsA(isA<EpochWrapNotFoundException>()));
      await pumpEventQueue();

      expect(events.single.reason, EpochBlockReason.wrapUnavailable);
      expect(events.single.epoch, 0);
    });

    test('a completed sync reports the album unblocked', () async {
      final s = await _bootStack();
      final cleared = <({String album, int epoch})>[];
      s.processor.unblocked
          .listen((e) => cleared.add((album: _hex(e.albumId), epoch: e.epoch)));
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      s.api.putWrap(
          s.albumIdStr,
          0,
          await s.admin.buildWrap(
              albumId: s.albumId,
              epoch: 0,
              mk: _mk(0xCC),
              responderBundle: bundle));

      await s.processor.handleEvent(albumId: s.albumId, epoch: 0);
      await pumpEventQueue();

      expect(cleared, [(album: _hex(s.albumId), epoch: 0)]);
    });

    test('catch up repairs a hole below the cursor', () async {
      // With [0, 2] stored and the server on 2, old latest+1 logic did no work
      // Catch up must inspect actual stored epochs to find 1
      final s = await _bootStack(pinAdmin: true);
      await s.aks.installVerified(
          albumId: s.albumId, epoch: 0, mk: _mk(0x10), backfill: false);
      await s.aks.installVerified(
          albumId: s.albumId, epoch: 2, mk: _mk(0x12), backfill: false);
      s.api.currents[s.albumIdStr] = EpochCurrent(
        currentEpoch: 2,
        startedAt: DateTime.utc(2026, 5, 7, 12),
      );
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      s.api.putWrap(
          s.albumIdStr,
          1,
          await s.admin.buildWrap(
              albumId: s.albumId,
              epoch: 1,
              mk: _mk(0x41),
              responderBundle: bundle));

      await s.processor.catchUpAll([s.albumId]);

      expect(await s.aks.presentEpochs(s.albumId), [0, 1, 2]);
    });

    test('an older duplicate event reports only the epoch it reached',
        () async {
      // Epoch 5 blocks; a delayed duplicate for 4 then succeeds trivially. It
      // must not claim to have caught up past the epoch that actually failed
      final s = await _bootStack(pinAdmin: true);
      for (var i = 0; i <= 4; i++) {
        await s.aks.installVerified(
            albumId: s.albumId, epoch: i, mk: _mk(0x10 + i), backfill: false);
      }
      final reached = <int>[];
      s.processor.unblocked.listen((e) => reached.add(e.epoch));

      await s.processor.handleEvent(albumId: s.albumId, epoch: 4);
      await pumpEventQueue();

      expect(reached, [4]);
    });

    test('a refused signer is evicted so a retry re-reads the roster',
        () async {
      // MemberDirectory caches per (album, token). Without eviction a retry
      // keeps re checking the same stale key and can never recover, even once
      // the server serves the honest one
      final responder = await newResponderIdentity();
      final admin = await SyntheticAdmin.create();
      final roster = _MutableRoster([
        MemberRecord(
          memberToken: admin.senderToken,
          ikPub: Uint8List.fromList(List<int>.filled(32, 0x5E)), // wrong key
          lkPub: admin.lkPub,
        ),
      ]);
      final api = FakeEpochApi();
      final aks = AlbumKeyStore(responder.store);
      await aks.initialize();
      final pins = <String, Uint8List>{
        _hex(admin.senderToken): admin.ikPub,
      };
      final processor = EpochProcessor(
        api: api,
        identity: responder.svc,
        store: aks,
        directory: MemberDirectory(roster.fetcher),
        signerGate: ExpectedIkResolver.responder(
          selfToken: (_) => null,
          pinned: (_, __) => null,
          signerPinned: (_, token) => pins[_hex(token)],
          currentIk: responder.svc.currentIkPub,
          soleSigner: (_) => false,
          pin: (_, token, ik) async => pins[_hex(token)] = ik,
        ),
      );
      final albumId = _albumId();
      final albumIdStr = uuidStringFromBytes(albumId);
      final bundle =
          await buildResponderBundle(responder: responder.svc, spkTs: _spkTs);
      api.putWrap(
          albumIdStr,
          0,
          await admin.buildWrap(
              albumId: albumId,
              epoch: 0,
              mk: _mk(0xCC),
              responderBundle: bundle));

      await expectLater(processor.handleEvent(albumId: albumId, epoch: 0),
          throwsA(isA<IdentitySignerMismatchException>()));
      expect(roster.fetches, 1);

      // server starts telling the truth; the retry must be able to see it
      roster.records[0] = MemberRecord(
        memberToken: admin.senderToken,
        ikPub: admin.ikPub,
        lkPub: admin.lkPub,
      );
      await processor.handleEvent(albumId: albumId, epoch: 0);

      expect(roster.fetches, 2);
      expect(await aks.presentEpochs(albumId), [0]);
    });

    test('a roster pin alone cannot authorize a new epoch signer', () async {
      // Opening the member list TOFU pins every unseen row. A server invented
      // member must not gain the right to sign epochs just by being displayed
      final s = await _bootStack();
      await s.aks.installVerified(
          albumId: s.albumId, epoch: 0, mk: _mk(0x10), backfill: false);
      s.rosterPins[_hex(s.admin.senderToken)] = s.admin.ikPub;
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      s.api.putWrap(
          s.albumIdStr,
          1,
          await s.admin.buildWrap(
              albumId: s.albumId,
              epoch: 1,
              mk: _mk(0xCC),
              responderBundle: bundle));

      await expectLater(s.processor.handleEvent(albumId: s.albumId, epoch: 1),
          throwsA(isA<UnknownSignerException>()));
      expect(await s.aks.presentEpochs(s.albumId), [0]);
    });

    test('an album awaiting our own epoch 0 refuses a peer signed wrap',
        () async {
      // Zero local MKs, so the plain TOFU rule would wave this through : but we
      // created this album, and it has never had an epoch for anyone to sign
      final s = await _bootStack();
      s.creating[0] = true;
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      s.api.putWrap(
          s.albumIdStr,
          0,
          await s.admin.buildWrap(
              albumId: s.albumId,
              epoch: 0,
              mk: _mk(0xCC),
              responderBundle: bundle));

      await expectLater(s.processor.handleEvent(albumId: s.albumId, epoch: 0),
          throwsA(isA<UnknownSignerException>()));
      expect(await s.aks.presentEpochs(s.albumId), isEmpty);
      expect(s.pins, isEmpty);
    });

    test('a missing local OPK surfaces as a blocked album', () async {
      final s = await _bootStack();
      final opkPub = Uint8List.fromList(List<int>.filled(32, 0x77));
      final bundle = await buildResponderBundle(
          responder: s.responder.svc,
          spkTs: _spkTs,
          opk: (idx: 4242, keyPub: opkPub)); // an index this device never had
      final events = <EpochBlocked>[];
      s.processor.blocked.listen(events.add);
      s.api.putWrap(
          s.albumIdStr,
          0,
          await s.admin.buildWrap(
              albumId: s.albumId,
              epoch: 0,
              mk: _mk(0xCC),
              responderBundle: bundle));

      await expectLater(s.processor.handleEvent(albumId: s.albumId, epoch: 0),
          throwsA(isA<OpkNotFoundException>()));
      await pumpEventQueue();

      expect(events.single.reason, EpochBlockReason.localKeyMissing);
    });

    test('a refused replay surfaces as a blocked album', () async {
      // The backfill path re installs 0..current unconditionally, so a server
      // re serving an epoch we hold with DIFFERENT bytes lands on the tamper
      // branch of installVerified rather than being skipped
      final s = await _bootStack(pinAdmin: true);
      await s.aks.installVerified(
          albumId: s.albumId, epoch: 0, mk: _mk(0x10), backfill: false);
      final bundle =
          await buildResponderBundle(responder: s.responder.svc, spkTs: _spkTs);
      s.api.putWrap(
          s.albumIdStr,
          0,
          await s.admin.buildWrap(
              albumId: s.albumId,
              epoch: 0,
              mk: _mk(0x99), // not the MK_0 we already hold
              responderBundle: bundle));
      final events = <EpochBlocked>[];
      s.processor.blocked.listen(events.add);

      await expectLater(
          s.processor.handleEvent(albumId: s.albumId, epoch: 0, joined: true),
          throwsA(isA<EpochReplayException>()));
      await pumpEventQueue();

      expect(events.single.reason, EpochBlockReason.replayRejected);
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
