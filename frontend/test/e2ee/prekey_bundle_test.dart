import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/e2ee/prekey_bundle.dart';

import '../_sodium_setup.dart';

// Tests cover both fromJson decoding and the §6 verify ordering rules
// (length -> ts skew -> Ed25519 sig). Synthesized JSON is built inline so we
// stay independent of the data layer adapter

Future<Map<String, dynamic>> _buildBundleJson({
  required Ed25519KeyPair ikKp,
  required Uint8List lkPub,
  required Uint8List spkPub,
  required int spkTs,
  Uint8List? overrideIkPub,
  Uint8List? overrideSpkSig,
  ({int idx, Uint8List keyPub})? opk,
}) async {
  final ikPub = overrideIkPub ?? ikKp.publicKey;
  Uint8List spkSig;
  if (overrideSpkSig != null) {
    spkSig = overrideSpkSig;
  } else {
    final msg = Uint8List(40);
    msg.setRange(0, 32, spkPub);
    ByteData.sublistView(msg, 32).setUint64(0, spkTs, Endian.big);
    spkSig = await Sign.sign(ikKp, msg);
  }
  final out = <String, dynamic>{
    'user_id': '11111111-2222-3333-4444-555555555555',
    'ik_pub': base64Encode(ikPub),
    'lk_pub': base64Encode(lkPub),
    'spk_pub': base64Encode(spkPub),
    'spk_sig': base64Encode(spkSig),
    'spk_ts': spkTs,
  };
  if (opk != null) {
    out['opk'] = {
      'idx': opk.idx,
      'key_pub': base64Encode(opk.keyPub),
    };
  }
  return out;
}

void main() {
  late Ed25519KeyPair ikKp;
  late Uint8List lkPub;
  late Uint8List spkPub;
  late Uint8List opkPub;
  final t0 = DateTime.utc(2026, 5, 4, 12);
  final tsNow = t0.millisecondsSinceEpoch ~/ 1000;

  setUpAll(() async {
    await ensureSodium();
    ikKp = await Sign.generateEd25519();
    final lkKp = await Kex.generateX25519();
    final spkKp = await Kex.generateX25519();
    final opkKp = await Kex.generateX25519();
    lkPub = lkKp.publicKey;
    spkPub = spkKp.publicKey;
    opkPub = opkKp.publicKey;
  });

  group('PrekeyBundle.fromJson', () {
    test('round-trips a valid response with OPK', () async {
      final json = await _buildBundleJson(
        ikKp: ikKp,
        lkPub: lkPub,
        spkPub: spkPub,
        spkTs: tsNow,
        opk: (idx: 7, keyPub: opkPub),
      );
      final b = PrekeyBundle.fromJson(json);

      expect(b.userId, '11111111-2222-3333-4444-555555555555');
      expect(b.ikPub.length, 32);
      expect(b.lkPub, orderedEquals(lkPub));
      expect(b.spkPub, orderedEquals(spkPub));
      expect(b.spkSig.length, 64);
      expect(b.spkTs, tsNow);
      expect(b.opk, isNotNull);
      expect(b.opk!.idx, 7);
      expect(b.opk!.keyPub, orderedEquals(opkPub));
    });

    test('round trips a bundle with no OPK (drained pool)', () async {
      final json = await _buildBundleJson(
        ikKp: ikKp,
        lkPub: lkPub,
        spkPub: spkPub,
        spkTs: tsNow,
      );
      final b = PrekeyBundle.fromJson(json);
      expect(b.opk, isNull);
    });
  });

  group('PrekeyBundle.verify', () {
    test('accepts a freshly signed valid bundle', () async {
      final json = await _buildBundleJson(
        ikKp: ikKp,
        lkPub: lkPub,
        spkPub: spkPub,
        spkTs: tsNow,
      );
      final b = PrekeyBundle.fromJson(json);
      await b.verify(now: () => t0);
    });

    test('rejects bad length before any sig math', () async {
      // 31 byte ik_pub should trip the length gate, never reach Ed25519
      final shortIk = Uint8List(31);
      final json = await _buildBundleJson(
        ikKp: ikKp,
        lkPub: lkPub,
        spkPub: spkPub,
        spkTs: tsNow,
        overrideIkPub: shortIk,
      );
      final b = PrekeyBundle.fromJson(json);
      await expectLater(
        b.verify(now: () => t0),
        throwsA(isA<BundleVerificationException>()
            .having((e) => e.reason, 'reason', 'length')),
      );
    });

    test('rejects ts older than 90d (ts_too_old)', () async {
      final stale = tsNow - (91 * 24 * 3600);
      final json = await _buildBundleJson(
        ikKp: ikKp,
        lkPub: lkPub,
        spkPub: spkPub,
        spkTs: stale,
      );
      final b = PrekeyBundle.fromJson(json);
      await expectLater(
        b.verify(now: () => t0),
        throwsA(isA<BundleVerificationException>()
            .having((e) => e.reason, 'reason', 'ts_too_old')),
      );
    });

    test('rejects ts more than 90d in the future (ts_in_future)', () async {
      final future = tsNow + (91 * 24 * 3600);
      final json = await _buildBundleJson(
        ikKp: ikKp,
        lkPub: lkPub,
        spkPub: spkPub,
        spkTs: future,
      );
      final b = PrekeyBundle.fromJson(json);
      await expectLater(
        b.verify(now: () => t0),
        throwsA(isA<BundleVerificationException>()
            .having((e) => e.reason, 'reason', 'ts_in_future')),
      );
    });

    test('rejects sig_invalid when one byte of spk_sig is flipped', () async {
      final json = await _buildBundleJson(
        ikKp: ikKp,
        lkPub: lkPub,
        spkPub: spkPub,
        spkTs: tsNow,
      );
      // Flip one byte in spk_sig before decoding to keep base64 valid
      final origSig = base64Decode(json['spk_sig'] as String);
      origSig[0] ^= 0x01;
      json['spk_sig'] = base64Encode(origSig);
      final b = PrekeyBundle.fromJson(json);
      await expectLater(
        b.verify(now: () => t0),
        throwsA(isA<BundleVerificationException>()
            .having((e) => e.reason, 'reason', 'sig_invalid')),
      );
    });

    test('rejects sig over a different message (wrong spkTs in payload)',
        () async {
      // Sign with the wrong ts so the verifier rebuilds a different msg
      final wrongTsForSig = tsNow + 1234;
      final msg = Uint8List(40);
      msg.setRange(0, 32, spkPub);
      ByteData.sublistView(msg, 32).setUint64(0, wrongTsForSig, Endian.big);
      final badSig = await Sign.sign(ikKp, msg);
      final json = await _buildBundleJson(
        ikKp: ikKp,
        lkPub: lkPub,
        spkPub: spkPub,
        spkTs: tsNow,
        overrideSpkSig: badSig,
      );
      final b = PrekeyBundle.fromJson(json);
      await expectLater(
        b.verify(now: () => t0),
        throwsA(isA<BundleVerificationException>()
            .having((e) => e.reason, 'reason', 'sig_invalid')),
      );
    });
  });
}
