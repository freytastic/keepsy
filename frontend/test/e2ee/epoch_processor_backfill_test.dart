import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/epoch_api.dart';
import 'package:keepsy/e2ee/epoch_processor.dart';
import 'package:keepsy/e2ee/invite_api.dart';
import 'package:keepsy/e2ee/join.dart';
import 'package:keepsy/e2ee/member_directory.dart';
import 'package:keepsy/secure_store/key_handle_adapter.dart';

import '../_sodium_setup.dart';
import '_admin_test_helpers.dart';

class _CaptureJoinApi implements InviteApi {
  int calls = 0;
  String? lastAlbum;
  int? lastEpoch;
  Uint8List? lastEk;
  Uint8List? lastSig;

  @override
  Future<void> postJoinComplete({
    required String albumId,
    required int epoch,
    required Uint8List ekPubAdmin,
    required Uint8List sig,
  }) async {
    calls++;
    lastAlbum = albumId;
    lastEpoch = epoch;
    lastEk = ekPubAdmin;
    lastSig = sig;
  }

  @override
  Future<Uint8List> deliverExistingUser({
    required String albumId,
    required String targetKeepsyId,
    required Uint8List ekPub,
    int? opkIdx,
    required List<DeliverEnvelope> envelopes,
  }) =>
      throw UnimplementedError();
}

void main() {
  setUpAll(ensureSodium);

  final fixed = DateTime.utc(2026, 5, 4, 12);
  final spkTs = fixed.millisecondsSinceEpoch ~/ 1000;
  final albumId = Uint8List.fromList(List.generate(16, (i) => i + 1));
  final albumStr = uuidStringFromBytes(albumId);
  final mks = <int, Uint8List>{
    for (var e = 0; e < 3; e++)
      e: Uint8List.fromList(List.filled(32, 0x20 + e)),
  };

  // Wires an admin who has delivered wraps for epochs 0..current to a fresh responder
  Future<
      ({
        EpochProcessor proc,
        AlbumKeyStore aks,
        _CaptureJoinApi invites,
        Uint8List bobIk,
      })> scenario({int currentEpoch = 2}) async {
    final admin = await SyntheticAdmin.create(now: fixed);
    final bob = await newResponderIdentity(now: fixed);
    final bobAks = AlbumKeyStore(bob.store);
    final bobBundle =
        await buildResponderBundle(responder: bob.svc, spkTs: spkTs);

    final api = FakeEpochApi();
    api.currents[albumStr] =
        EpochCurrent(currentEpoch: currentEpoch, startedAt: fixed);
    for (var e = 0; e <= currentEpoch; e++) {
      api.putWrap(
        albumStr,
        e,
        await admin.buildWrap(
            albumId: albumId,
            epoch: e,
            mk: mks[e]!,
            responderBundle: bobBundle),
      );
    }

    final invites = _CaptureJoinApi();
    final proc = EpochProcessor(
      api: api,
      identity: bob.svc,
      store: bobAks,
      directory: MemberDirectory(singletonAdminFetcher(admin)),
      invites: invites,
    );
    final bobIk = await bob.svc.useIk<Uint8List>(
        (seed) async => (await KeyHandleAdapter.toEd25519(seed)).publicKey);
    return (proc: proc, aks: bobAks, invites: invites, bobIk: bobIk);
  }

  test('live joined event backfills all epochs and posts one receipt',
      () async {
    final s = await scenario();
    await s.proc.handleEvent(albumId: albumId, epoch: 2, joined: true);

    expect(await s.aks.presentEpochs(albumId), [0, 1, 2]);
    for (final e in mks.keys) {
      final got = await s.aks
          .useMk<Uint8List>(albumId, e, (mk) async => Uint8List.fromList(mk));
      expect(got, equals(mks[e]), reason: 'epoch $e MK installed');
    }
    expect(s.invites.calls, 1);
    expect(s.invites.lastEpoch, 2);
    expect(s.invites.lastAlbum, albumStr);

    // Receipt is signed by Bob's IK over the join-complete-v1 message
    final ok = await Sign.verify(s.bobIk,
        joinCompleteMsg(albumId, 2, s.invites.lastEk!), s.invites.lastSig!);
    expect(ok, isTrue);
  });

  test('cold start (zero local MKs) backfills via catchUpAll + posts receipt',
      () async {
    final s = await scenario();
    // No WS event , the new member missed the live emit : catch-up detects latest==-1
    await s.proc.catchUpAll([albumId]);

    expect(await s.aks.presentEpochs(albumId), [0, 1, 2]);
    expect(s.invites.calls, 1);
    expect(s.invites.lastEpoch, 2);
  });

  test('backfill is idempotent: a repeat join event does not throw or regress',
      () async {
    final s = await scenario();
    await s.proc.handleEvent(albumId: albumId, epoch: 2, joined: true);
    // Duplicate event: backfill:true re installs byte-equal MKs without error
    await s.proc.handleEvent(albumId: albumId, epoch: 2, joined: true);
    expect(await s.aks.presentEpochs(albumId), [0, 1, 2]);
    expect(s.invites.calls, 2); // each event posts : server GREATEST dedupes
  });
}
