import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/e2ee/epoch_api.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/e2ee/member_directory.dart';
import 'package:keepsy/e2ee/prekey_api.dart';
import 'package:keepsy/e2ee/prekey_bundle.dart';
import 'package:keepsy/e2ee/wrap_envelope.dart';
import 'package:keepsy/e2ee/x3dh_session.dart';
import 'package:keepsy/secure_store/key_handle_adapter.dart';

import '../secure_store/mock_secure_key_store.dart';
import 'identity_label_map_test_helpers.dart';

// Test only synthetic admin. Owns its own IK seed (Ed25519) + LK priv (X25519)
// + senderToken : builds wraps via X3dhSession.initiate against the responder
// (whose IdentityService exposes the matching responder side bundle), encrypts
// MK under SK with AAD = album_id ‖ u32_be(epoch) (§4.1) and signs the
// SHA256(album_id ‖ u32_be(epoch) ‖ wrap_blob) message under its IK (§4.2 D3)
// Filename starts with `_` so it is not exported as part of the test catalog

// Silent API with an injectable lost-response rotation failure
class SilentPrekeyApi implements PrekeyApi {
  PrekeyApiException? rotateError;
  int fetchOwnKeysCalls = 0;
  OwnKeys own = OwnKeys(
      ikPub: Uint8List(0),
      lkPub: Uint8List(0),
      spkPub: Uint8List(0),
      spkTs: null);

  @override
  Future<int> opkCount() async => 20;

  @override
  Future<OwnKeys> fetchOwnKeys() async {
    fetchOwnKeysCalls++;
    return own;
  }

  @override
  Future<void> replenishOpks(
      {required List<PrekeyOpk> opks, required Uint8List replenishSig}) async {}
  @override
  Future<void> rotateSpk(
      {required Uint8List spkPub,
      required Uint8List spkSig,
      required int spkTs,
      required Uint8List rotationSig}) async {
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
  Future<PrekeyBundle> fetchPrekeyBundleByHandle(String handle) =>
      throw UnimplementedError();

  @override
  Future<PrekeyBundle> fetchPrekeyBundle(String userId) async {
    throw UnimplementedError();
  }
}

class SyntheticAdmin {
  final IdentityService _svc;
  final Uint8List senderToken;
  final Uint8List ikPub;
  final Uint8List lkPub;

  SyntheticAdmin._(this._svc, this.senderToken, this.ikPub, this.lkPub);

  static Future<SyntheticAdmin> create({DateTime? now}) async {
    final fixed = now ?? DateTime.utc(2026, 5, 4, 12);
    final store = MockSecureKeyStore();
    await store.initialize();
    final labels = makeInMemoryLabelMap();
    await labels.load();
    final svc = IdentityService(
      store: store,
      labels: labels,
      api: SilentPrekeyApi(),
      now: () => fixed,
    );
    await svc.bootstrap();
    final ikPub = await svc.useIk<Uint8List>((seed) async {
      final kp = await KeyHandleAdapter.toEd25519(seed);
      return kp.publicKey;
    });
    final lkPub = await svc.useLk<Uint8List>((priv) async {
      final kp = await KeyHandleAdapter.toX25519(priv);
      return kp.publicKey;
    });
    return SyntheticAdmin._(svc, Csprng.bytes(32), ikPub, lkPub);
  }

  // Builds a complete signed WrapEnvelope. PrekeyBundle is the responder's,
  // synthesized by buildResponderBundle. Caller supplies the MK : the helper
  // returns a (envelope, sharedSecretSnapshot) pair so tests can drop the SK
  // after install
  Future<WrapEnvelope> buildWrap({
    required Uint8List albumId,
    required int epoch,
    required Uint8List mk,
    required PrekeyBundle responderBundle,
    int aadEpochOverride =
        -1, // -1 means "use 'epoch'" : otherwise inject for §10.2 #10
    int sigEpochOverride = -1, // -1 means "sign the epoch we encoded"
    DateTime? deliveredAt,
  }) async {
    final init = await X3dhSession.initiate(
      bundle: responderBundle,
      albumId: albumId,
      identity: _svc,
    );
    final usedAad = aadEpochOverride < 0 ? epoch : aadEpochOverride;
    final aad = _aad(albumId, usedAad);
    // Aead.encrypt picks a fresh 96 bit nonce : output is 0x01 ‖ nonce ‖ tag ‖ ct
    final wrap = await Aead.encrypt(
      version: 0x01,
      key: init.sharedSecret,
      plaintext: mk,
      aad: aad,
    );
    final sigEpoch = sigEpochOverride < 0 ? epoch : sigEpochOverride;
    final msg = await _msgToSign(albumId, sigEpoch, wrap);
    final sig = await _svc.useIk<Uint8List>((seed) async {
      final kp = await KeyHandleAdapter.toEd25519(seed);
      return Sign.sign(kp, msg);
    });
    init.sharedSecret.fillRange(0, init.sharedSecret.length, 0);
    return WrapEnvelope(
      epoch: epoch,
      ekPub: init.ekPub,
      wrap: wrap,
      senderToken: senderToken,
      senderSig: sig,
      opkIdxUsed: init.opkIdx,
      deliveredAt: deliveredAt ?? DateTime.utc(2026, 5, 7, 12),
    );
  }
}

// Pulls the responder's pubs and builds a verified bundle the admin can
// initiate against. Mirrors test/e2ee/x3dh_session_test._buildVerifiedBundle
Future<PrekeyBundle> buildResponderBundle({
  required IdentityService responder,
  required int spkTs,
  ({int idx, Uint8List keyPub})? opk,
  SpkSlot slot = SpkSlot.current,
}) async {
  final ikPub = await responder.useIk<Uint8List>((seed) async {
    final kp = await KeyHandleAdapter.toEd25519(seed);
    return kp.publicKey;
  });
  final lkPub = await responder.useLk<Uint8List>((priv) async {
    final kp = await KeyHandleAdapter.toX25519(priv);
    return kp.publicKey;
  });
  final spkPub = await responder.useSpk<Uint8List>((priv) async {
    final kp = await KeyHandleAdapter.toX25519(priv);
    return kp.publicKey;
  }, slot: slot);
  final msg = Uint8List(40);
  msg.setRange(0, 32, spkPub);
  ByteData.sublistView(msg, 32).setUint64(0, spkTs, Endian.big);
  final spkSig = await responder.useIk<Uint8List>((seed) async {
    final kp = await KeyHandleAdapter.toEd25519(seed);
    return Sign.sign(kp, msg);
  });
  final json = <String, dynamic>{
    'user_id': '11111111-2222-3333-4444-555555555555',
    'ik_pub': base64Encode(ikPub),
    'lk_pub': base64Encode(lkPub),
    'spk_pub': base64Encode(spkPub),
    'spk_sig': base64Encode(spkSig),
    'spk_ts': spkTs,
  };
  if (opk != null) {
    json['opk'] = {'idx': opk.idx, 'key_pub': base64Encode(opk.keyPub)};
  }
  return PrekeyBundle.fromJson(json);
}

// Bootstrapped responder side IdentityService backed by an in memory secure
// store + label map. Returned alongside the store so tests can layer
// AlbumKeyStore on the same SecureKeyStore (so installVerified -> store.put
// and AlbumKeyStore.initialize round trips through .list)
Future<({IdentityService svc, MockSecureKeyStore store, SilentPrekeyApi api})>
    newResponderIdentity({DateTime? now, DateTime Function()? nowFn}) async {
  final clock = nowFn ?? () => (now ?? DateTime.utc(2026, 5, 4, 12));
  final store = MockSecureKeyStore();
  await store.initialize();
  final labels = makeInMemoryLabelMap();
  await labels.load();
  final api = SilentPrekeyApi();
  final svc = IdentityService(
    store: store,
    labels: labels,
    api: api,
    now: clock,
  );
  await svc.bootstrap();
  return (svc: svc, store: store, api: api);
}

// In memory MemberFetcher snapshot. Tests register the synthetic admin against
// a single albumId and pass this into MemberDirectory's constructor
MemberFetcher singletonAdminFetcher(SyntheticAdmin admin) {
  return (Uint8List _) async => [
        MemberRecord(
          memberToken: admin.senderToken,
          ikPub: admin.ikPub,
          lkPub: admin.lkPub,
        ),
      ];
}

// In memory EpochApi stub. Tests pre populate per (albumId, epoch) wraps and
// (optionally) a current epoch. getWrap returns from the map : missing entries
// throw EpochWrapNotFoundException so the processor's 404 retry path can be
// exercised. The 404 counter is per (albumId, epoch) so tests can have the
// nth fetch succeed
class FakeEpochApi implements EpochApi {
  final Map<String, EpochCurrent> currents = {};
  final Map<String, WrapEnvelope> wraps = {};
  final Map<String, int> notFoundCounters = {}; // remaining 404 count
  final List<({String albumId, int epoch})> fetchLog = [];

  @override
  Future<EpochCurrent?> getCurrentEpoch(String albumId) async =>
      currents[albumId];

  @override
  Future<WrapEnvelope> getWrap(String albumId, int epoch) async {
    fetchLog.add((albumId: albumId, epoch: epoch));
    final key = '$albumId:$epoch';
    final remaining = notFoundCounters[key] ?? 0;
    if (remaining > 0) {
      notFoundCounters[key] = remaining - 1;
      throw EpochWrapNotFoundException(albumId, epoch);
    }
    final w = wraps[key];
    if (w == null) {
      throw EpochWrapNotFoundException(albumId, epoch);
    }
    return w;
  }

  // setEpoch : unused by the responder side tests but required to satisfy
  // EpochApi. Use _CaptureEpochApi in epoch_rotator_test.dart for initiator
  // assertions
  @override
  Future<void> setEpoch(String _, SetEpochRequest __) async {
    throw UnimplementedError('FakeEpochApi.setEpoch not stubbed');
  }

  void putWrap(String albumId, int epoch, WrapEnvelope env) {
    wraps['$albumId:$epoch'] = env;
  }

  void setNotFoundCount(String albumId, int epoch, int n) {
    notFoundCounters['$albumId:$epoch'] = n;
  }
}

// 16-byte UUID -> canonical 8-4-4-4-12 string. Mirrors the helper in
// epoch_processor.dart so tests can address FakeEpochApi by string
String uuidStringFromBytes(Uint8List b) {
  final s = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
      '-${s.substring(16, 20)}-${s.substring(20)}';
}

Uint8List _aad(Uint8List albumId, int epoch) {
  final out = Uint8List(16 + 4);
  out.setRange(0, 16, albumId);
  ByteData.sublistView(out, 16, 20).setUint32(0, epoch, Endian.big);
  return out;
}

Future<Uint8List> _msgToSign(
    Uint8List albumId, int epoch, Uint8List wrap) async {
  final buf = Uint8List(16 + 4 + wrap.length);
  buf.setRange(0, 16, albumId);
  ByteData.sublistView(buf, 16, 20).setUint32(0, epoch, Endian.big);
  buf.setRange(20, buf.length, wrap);
  final h = await cg.Sha256().hash(buf);
  return Uint8List.fromList(h.bytes);
}
