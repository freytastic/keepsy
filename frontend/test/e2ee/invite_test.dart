import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/invite.dart';
import 'package:keepsy/e2ee/invite_api.dart';
import 'package:keepsy/e2ee/prekey_api.dart';
import 'package:keepsy/e2ee/prekey_bundle.dart';
import 'package:keepsy/e2ee/x3dh_session.dart';
import 'package:keepsy/secure_store/key_handle_adapter.dart';

import '../_sodium_setup.dart';
import '_admin_test_helpers.dart';

class _ByHandlePrekeyApi implements PrekeyApi {
  final PrekeyBundle bundle;
  _ByHandlePrekeyApi(this.bundle);

  @override
  Future<PrekeyBundle> fetchPrekeyBundleByHandle(String handle) async => bundle;

  @override
  Future<PrekeyBundle> fetchPrekeyBundle(String userId) =>
      throw UnimplementedError();
  @override
  Future<int> opkCount() async => 0;
  @override
  Future<void> replenishOpks(
      {required List<PrekeyOpk> opks, required Uint8List replenishSig}) async {}
  @override
  Future<void> rotateSpk(
      {required Uint8List spkPub,
      required Uint8List spkSig,
      required int spkTs,
      required Uint8List rotationSig}) async {}
  @override
  Future<void> upsertIdentity(
      {required Uint8List ikPub,
      required Uint8List lkPub,
      required Uint8List spkPub,
      required Uint8List spkSig,
      required int spkTs}) async {}
}

class _CaptureInviteApi implements InviteApi {
  String? albumId;
  String? targetKeepsyId;
  Uint8List? ekPub;
  int? opkIdx;
  List<DeliverEnvelope> envelopes = const [];

  @override
  Future<Uint8List> deliverExistingUser({
    required String albumId,
    required String targetKeepsyId,
    required Uint8List ekPub,
    int? opkIdx,
    required List<DeliverEnvelope> envelopes,
  }) async {
    this.albumId = albumId;
    this.targetKeepsyId = targetKeepsyId;
    this.ekPub = ekPub;
    this.opkIdx = opkIdx;
    this.envelopes = envelopes;
    return Uint8List.fromList(List.filled(32, 0xAB));
  }

  @override
  Future<void> postJoinComplete(
      {required String albumId,
      required int epoch,
      required Uint8List ekPubAdmin,
      required Uint8List sig}) async {}
}

String _pinKey(Uint8List albumId, Uint8List token) =>
    '${base64Encode(albumId)}:${base64Encode(token)}';

Uint8List _aad(Uint8List albumId, int epoch) {
  final out = Uint8List(20);
  out.setRange(0, 16, albumId);
  ByteData.sublistView(out, 16).setUint32(0, epoch, Endian.big);
  return out;
}

Future<Uint8List> _senderMsg(
    Uint8List albumId, int epoch, Uint8List wrap) async {
  final buf = Uint8List(20 + wrap.length);
  buf.setRange(0, 16, albumId);
  ByteData.sublistView(buf, 16, 20).setUint32(0, epoch, Endian.big);
  buf.setRange(20, buf.length, wrap);
  final h = await cg.Sha256().hash(buf);
  return Uint8List.fromList(h.bytes);
}

void main() {
  setUpAll(ensureSodium);

  final fixed = DateTime.utc(2026, 5, 4, 12);
  final spkTs = fixed.millisecondsSinceEpoch ~/ 1000;
  final albumId = Uint8List.fromList(List.generate(16, (i) => i + 1));

  late Object
      aliceSvcRaw; // IdentityService, kept loosely typed for pub helpers

  test('inviteExistingUser wraps every epoch under one X3DH; invitee decrypts',
      () async {
    final alice = await newResponderIdentity(now: fixed);
    final bob = await newResponderIdentity(now: fixed);
    aliceSvcRaw = alice.svc;

    final aliceAks = AlbumKeyStore(alice.store);
    final mks = <int, Uint8List>{
      for (var e = 0; e < 3; e++)
        e: Uint8List.fromList(List.filled(32, 0x10 + e)),
    };
    for (final e in mks.keys) {
      await aliceAks.install(albumId, e, mks[e]!);
    }

    final aliceIkPub = await alice.svc.useIk<Uint8List>(
        (seed) async => (await KeyHandleAdapter.toEd25519(seed)).publicKey);
    final aliceLkPub = await alice.svc.useLk<Uint8List>(
        (priv) async => (await KeyHandleAdapter.toX25519(priv)).publicKey);

    // 3-DH bundle (no OPK): keeps the responder derive free of OPK plumbing
    final bobBundle =
        await buildResponderBundle(responder: bob.svc, spkTs: spkTs);

    final capture = _CaptureInviteApi();
    final initiator = InviteInitiator(
      prekeys: _ByHandlePrekeyApi(bobBundle),
      invites: capture,
      identity: alice.svc,
      aks: aliceAks,
      now: () => fixed,
    );

    final token = await initiator.inviteExistingUser(
        keepsyId: 'K7F29QXM', albumId: albumId);
    expect(token.length, 32);
    expect(capture.targetKeepsyId, 'K7F29QXM');
    expect(capture.envelopes.length, 3);

    for (var i = 0; i < 3; i++) {
      final env = capture.envelopes[i];
      expect(env.epoch, i);
      expect(env.wrapNonce.length, 12);
      expect(env.wrapTagCt.length, 48);
      expect(env.senderSig.length, 64);

      // Reconstruct the 61B wire the server would hand back, then unwrap on Bob's side
      final wrap = Uint8List(1 + 12 + 48)
        ..[0] = 0x01
        ..setRange(1, 13, env.wrapNonce)
        ..setRange(13, 61, env.wrapTagCt);

      final bobSk = await X3dhSession.derive(
        identity: bob.svc,
        ekPub: capture.ekPub!,
        peerLkPub: aliceLkPub,
        opkIdx: capture.opkIdx,
        albumId: albumId,
      );
      final mk =
          await Aead.decrypt(wire: wrap, key: bobSk, aad: _aad(albumId, i));
      expect(mk, equals(mks[i]), reason: 'epoch $i MK must round-trip');

      // sender_sig verifies against Alice's IK over the §4.2 D3 message
      final ok = await Sign.verify(
          aliceIkPub, await _senderMsg(albumId, i, wrap), env.senderSig);
      expect(ok, isTrue, reason: 'epoch $i sender_sig must verify');

      bobSk.fillRange(0, bobSk.length, 0);
    }

    expect(aliceSvcRaw, isNotNull);
  });

  test('pins the invite bundle IK under the returned member_token', () async {
    final alice = await newResponderIdentity(now: fixed);
    final bob = await newResponderIdentity(now: fixed);
    final aliceAks = AlbumKeyStore(alice.store);
    await aliceAks.install(
        albumId, 0, Uint8List.fromList(List.filled(32, 0x55)));

    final bobBundle =
        await buildResponderBundle(responder: bob.svc, spkTs: spkTs);

    final pins = <String, Uint8List>{};
    final pinner = InviteIdentityPinner(
      pinnedIk: (a, t) => pins[_pinKey(a, t)],
      pin: (a, t, ik) async => pins[_pinKey(a, t)] = ik,
    );

    final token = await InviteInitiator(
      prekeys: _ByHandlePrekeyApi(bobBundle),
      invites: _CaptureInviteApi(),
      identity: alice.svc,
      aks: aliceAks,
      pinner: pinner,
      now: () => fixed,
    ).inviteExistingUser(keepsyId: 'K7F29QXM', albumId: albumId);

    // pinned under the SAME token the roster will later show, to the exact IK
    // the MK wraps went to
    expect(pins[_pinKey(albumId, token)], equals(bobBundle.ikPub));
  });

  test('does not clobber an existing pin on re-invite', () async {
    final alice = await newResponderIdentity(now: fixed);
    final bob = await newResponderIdentity(now: fixed);
    final aliceAks = AlbumKeyStore(alice.store);
    await aliceAks.install(
        albumId, 0, Uint8List.fromList(List.filled(32, 0x55)));

    final bobBundle =
        await buildResponderBundle(responder: bob.svc, spkTs: spkTs);

    // the server reuses the same token when re-inviting a previously kicked
    // member (0xAB..): pre-seed a prior baseline for it
    final reusedToken = Uint8List.fromList(List.filled(32, 0xAB));
    final priorIk = Uint8List.fromList(List.filled(32, 0x77));
    final pins = <String, Uint8List>{_pinKey(albumId, reusedToken): priorIk};
    final pinner = InviteIdentityPinner(
      pinnedIk: (a, t) => pins[_pinKey(a, t)],
      pin: (a, t, ik) async => pins[_pinKey(a, t)] = ik,
    );

    await InviteInitiator(
      prekeys: _ByHandlePrekeyApi(bobBundle),
      invites: _CaptureInviteApi(),
      identity: alice.svc,
      aks: aliceAks,
      pinner: pinner,
      now: () => fixed,
    ).inviteExistingUser(keepsyId: 'K7F29QXM', albumId: albumId);

    // the prior baseline stands : a substituting server still trips 'changed'
    expect(pins[_pinKey(albumId, reusedToken)], equals(priorIk));
  });

  test('tampered AAD (wrong epoch) fails authentication', () async {
    final alice = await newResponderIdentity(now: fixed);
    final bob = await newResponderIdentity(now: fixed);
    final aliceAks = AlbumKeyStore(alice.store);
    await aliceAks.install(
        albumId, 0, Uint8List.fromList(List.filled(32, 0x55)));

    final bobBundle =
        await buildResponderBundle(responder: bob.svc, spkTs: spkTs);
    final capture = _CaptureInviteApi();
    await InviteInitiator(
      prekeys: _ByHandlePrekeyApi(bobBundle),
      invites: capture,
      identity: alice.svc,
      aks: aliceAks,
      now: () => fixed,
    ).inviteExistingUser(keepsyId: 'K7F29QXM', albumId: albumId);

    final env = capture.envelopes.single;
    final wrap = Uint8List(61)
      ..[0] = 0x01
      ..setRange(1, 13, env.wrapNonce)
      ..setRange(13, 61, env.wrapTagCt);
    final bobSk = await X3dhSession.derive(
      identity: bob.svc,
      ekPub: capture.ekPub!,
      peerLkPub: await alice.svc.useLk<Uint8List>(
          (priv) async => (await KeyHandleAdapter.toX25519(priv)).publicKey),
      opkIdx: capture.opkIdx,
      albumId: albumId,
    );
    // Decrypt with the wrong epoch in the AAD → tag mismatch
    expect(
      () => Aead.decrypt(wire: wrap, key: bobSk, aad: _aad(albumId, 99)),
      throwsA(isA<AeadAuthFailed>()),
    );
  });
}
