import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/epoch_api.dart';
import 'package:keepsy/e2ee/epoch_processor.dart';
import 'package:keepsy/e2ee/member_directory.dart';
import 'package:keepsy/e2ee/wrap_envelope.dart';

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
}) async {
  final id = albumId ?? _albumId();
  final responder = await newResponderIdentity();
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
    responder: responder.svc,
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
          await buildResponderBundle(responder: s.responder, spkTs: _spkTs);
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
          await buildResponderBundle(responder: s.responder, spkTs: _spkTs);
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
          await buildResponderBundle(responder: s.responder, spkTs: _spkTs);
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
          await buildResponderBundle(responder: s.responder, spkTs: _spkTs);
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

    test('sender_sig invalid -> WrapVerificationException(sig_invalid)',
        () async {
      final s = await _bootStack();
      final mk = _mk(0x77);
      final bundle =
          await buildResponderBundle(responder: s.responder, spkTs: _spkTs);
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
