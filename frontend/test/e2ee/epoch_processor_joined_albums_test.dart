import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/epoch_api.dart';
import 'package:keepsy/e2ee/epoch_processor.dart';
import 'package:keepsy/e2ee/invite_api.dart';
import 'package:keepsy/e2ee/member_directory.dart';

import '../_sodium_setup.dart';
import '_admin_test_helpers.dart';

class _CapturingInvites implements InviteApi {
  int calls = 0;
  bool throwOnJoinComplete = false;

  @override
  Future<void> postJoinComplete({
    required String albumId,
    required int epoch,
    required Uint8List ekPubAdmin,
    required Uint8List sig,
  }) async {
    calls++;
    if (throwOnJoinComplete)
      throw StateError('simulated join_complete failure');
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

  Future<({EpochProcessor proc, _CapturingInvites invites})> scenario({
    int currentEpoch = 2,
    bool joinCompleteThrows = false,
  }) async {
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
    final invites = _CapturingInvites()
      ..throwOnJoinComplete = joinCompleteThrows;
    final proc = EpochProcessor(
      api: api,
      identity: bob.svc,
      store: bobAks,
      directory: MemberDirectory(singletonAdminFetcher(admin)),
      signerGate: tofuGate(),
      invites: invites,
    );
    return (proc: proc, invites: invites);
  }

  test('joinedAlbums emits after live joined:true + receipt', () async {
    final s = await scenario();
    final received = <Uint8List>[];
    final sub = s.proc.joinedAlbums.listen(received.add);
    await s.proc.handleEvent(albumId: albumId, epoch: 2, joined: true);
    // give the stream a microtask to deliver
    await Future<void>.delayed(Duration.zero);
    expect(received, hasLength(1));
    expect(received.first, equals(albumId));
    expect(s.invites.calls, 1);
    await sub.cancel();
  });

  test('joinedAlbums emits on cold-start catchUpAll join path', () async {
    final s = await scenario();
    final received = <Uint8List>[];
    final sub = s.proc.joinedAlbums.listen(received.add);
    await s.proc.catchUpAll([albumId]);
    await Future<void>.delayed(Duration.zero);
    expect(received, hasLength(1));
    expect(received.first, equals(albumId));
    await sub.cancel();
  });

  test('joinedAlbums does NOT emit when postJoinComplete throws', () async {
    final s = await scenario(joinCompleteThrows: true);
    final received = <Uint8List>[];
    final sub = s.proc.joinedAlbums.listen(received.add);
    await expectLater(
      s.proc.handleEvent(albumId: albumId, epoch: 2, joined: true),
      throwsA(isA<StateError>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(received, isEmpty);
    await sub.cancel();
  });
}
