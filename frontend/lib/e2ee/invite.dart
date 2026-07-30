import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/secure_store/key_handle_adapter.dart';

import 'album_keys.dart';
import 'identity.dart';
import 'invite_api.dart';
import 'prekey_api.dart';
import 'x3dh_session.dart';

typedef PinnedIkLookupFn = Uint8List? Function(
    Uint8List albumId, Uint8List memberToken);
typedef PinIkFn = Future<void> Function(
    Uint8List albumId, Uint8List memberToken, Uint8List ikPub);

// Anchors first contact TOFU on the IK we ACTUALLY wrapped the album MKs to
// bundle.verify() only proves the bundle signed itself : at first contact there
// is no prior identity to compare against, so a server could hand us an
// impostor's valid bundle. Pinning the invite IK does NOT defeat that (only an
// out ofband safety number can) but it makes a LATER roster showing a
// different IK for this member fire 'changed' instead of masquerading as an
// innocent first sight, and keeps the safety number honest about the encrypted
// to key. Advisory, like IdentityTrust : if unwired, invite still delivers
class InviteIdentityPinner {
  final PinnedIkLookupFn _pinnedIk;
  final PinIkFn _pin;
  InviteIdentityPinner({
    required PinnedIkLookupFn pinnedIk,
    required PinIkFn pin,
  })  : _pinnedIk = pinnedIk,
        _pin = pin;

  // Pin the invite IK, but NEVER clobber an existing baseline : a reinvited
  // member (token reused after a kick) keeps the pin from before, so a server
  // substituting at re invite still trips the change alarm instead of silently
  // moving the pin onto the impostor
  Future<void> anchor(
      Uint8List albumId, Uint8List memberToken, Uint8List ikPub) async {
    if (_pinnedIk(albumId, memberToken) != null) return;
    await _pin(albumId, memberToken, ikPub);
  }
}

// Looks up the invitee's bundle by keepsy_id, runs ONE X3DH,
// wraps every locally held MK (0..current) under the single shared secret, signs
// each per §4.2 D3, and ships them. Async for recipient : the invitee redeems
// later via EpochProcessor backfill. The shared secret is zeroed after delivery
class InviteInitiator {
  final PrekeyApi _prekeys;
  final InviteApi _invites;
  final IdentityService _identity;
  final AlbumKeyStore _aks;
  final InviteIdentityPinner? _pinner;
  final Now _now;

  InviteInitiator({
    required PrekeyApi prekeys,
    required InviteApi invites,
    required IdentityService identity,
    required AlbumKeyStore aks,
    InviteIdentityPinner? pinner,
    Now? now,
  })  : _prekeys = prekeys,
        _invites = invites,
        _identity = identity,
        _aks = aks,
        _pinner = pinner,
        _now = now ?? DateTime.now;

  // Returns the new member_token minted by the server
  Future<Uint8List> inviteExistingUser({
    required String keepsyId,
    required Uint8List albumId,
  }) async {
    final bundle = await _prekeys.fetchPrekeyBundleByHandle(keepsyId);
    await bundle.verify(now: _now);

    final init = await X3dhSession.initiate(
      bundle: bundle,
      albumId: albumId,
      identity: _identity,
    );
    try {
      final epochs = await _aks.presentEpochs(albumId);
      if (epochs.isEmpty) {
        throw StateError('inviteExistingUser: no local MKs for this album');
      }
      for (var i = 0; i < epochs.length; i++) {
        if (epochs[i] != i) {
          throw StateError(
              'inviteExistingUser: local MKs not contiguous from 0: $epochs');
        }
      }

      // Wrap every epoch's MK under the one shared secret + build the per epoch
      // sign messages. useMk pulls each MK through the keystore
      final wraps = <Uint8List>[]; // full 61B VER‖NONCE‖TAG‖CT per epoch
      final senderMsgs = <Uint8List>[];
      for (final e in epochs) {
        final wrap = await _aks.useMk<Uint8List>(
          albumId,
          e,
          (mk) => _wrapMk(
              sk: init.sharedSecret, mk: mk, albumId: albumId, epoch: e),
        );
        wraps.add(wrap);
        senderMsgs.add(await _senderMsg(albumId, e, wrap));
      }

      // One IK fetch signs every sender message (D11 keystore batching)
      final senderSigs = await _identity.useIk<List<Uint8List>>((seed) async {
        final kp = await KeyHandleAdapter.toEd25519(seed);
        final sigs = <Uint8List>[];
        for (final m in senderMsgs) {
          sigs.add(await Sign.sign(kp, m));
        }
        return sigs;
      });

      final envelopes = <DeliverEnvelope>[
        for (var i = 0; i < epochs.length; i++)
          DeliverEnvelope(
            epoch: epochs[i],
            wrapNonce: Uint8List.sublistView(wraps[i], 1, 1 + 12),
            wrapTagCt: Uint8List.sublistView(wraps[i], 1 + 12),
            senderSig: senderSigs[i],
          ),
      ];

      final token = await _invites.deliverExistingUser(
        albumId: _uuidString(albumId),
        targetKeepsyId: keepsyId,
        ekPub: init.ekPub,
        opkIdx: init.opkIdx,
        envelopes: envelopes,
      );
      // anchor TOFU on the key we just wrapped to, under the token the roster
      // will report for this member
      await _pinner?.anchor(albumId, token, bundle.ikPub);
      return token;
    } finally {
      init.sharedSecret.fillRange(0, init.sharedSecret.length, 0);
    }
  }

  // AES-GCM(SK, fresh nonce, MK, aad = album_id ‖ u32_be(epoch)) → 61B wire
  Future<Uint8List> _wrapMk({
    required Uint8List sk,
    required Uint8List mk,
    required Uint8List albumId,
    required int epoch,
  }) {
    final aad = Uint8List(16 + 4);
    aad.setRange(0, 16, albumId);
    ByteData.sublistView(aad, 16).setUint32(0, epoch, Endian.big);
    return Aead.encrypt(version: kVerAesGcm, key: sk, plaintext: mk, aad: aad);
  }

  // SHA256(album_id ‖ u32_be(epoch) ‖ wrap_blob) per §4.2 D3
  Future<Uint8List> _senderMsg(
      Uint8List albumId, int epoch, Uint8List wrap) async {
    final buf = Uint8List(16 + 4 + wrap.length);
    buf.setRange(0, 16, albumId);
    ByteData.sublistView(buf, 16, 20).setUint32(0, epoch, Endian.big);
    buf.setRange(20, buf.length, wrap);
    final h = await cg.Sha256().hash(buf);
    return Uint8List.fromList(h.bytes);
  }

  String _uuidString(Uint8List albumId) {
    if (albumId.length != 16) {
      throw ArgumentError('albumId must be 16 bytes, got ${albumId.length}');
    }
    final s = albumId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
        '-${s.substring(16, 20)}-${s.substring(20)}';
  }
}
