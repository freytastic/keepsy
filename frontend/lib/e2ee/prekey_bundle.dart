import 'dart:convert';
import 'dart:typed_data';

import 'package:keepsy/crypto/primitives.dart';

import 'identity.dart' show Now;

// PrekeyBundle is the GET /users/{id}/prekey-bundle response decoded into
// raw bytes. verify() runs the §6 length -> ts skew -> Ed25519 sig checks
// the caller MUST gate on before X3dhSession.initiate. fetchPrekeyBundle
// stays bytes in / bytes out so the network layer doesnt re-do the math

class PrekeyBundle {
  final String userId;
  final Uint8List ikPub;
  final Uint8List lkPub;
  final Uint8List spkPub;
  final Uint8List spkSig;
  final int spkTs;
  final BundleOpk? opk;

  const PrekeyBundle({
    required this.userId,
    required this.ikPub,
    required this.lkPub,
    required this.spkPub,
    required this.spkSig,
    required this.spkTs,
    this.opk,
  });

  // Mirrors prekey/handler.go::GetPrekeyBundle. spk_ts is a JSON number; some
  // libs widen it to double once it crosses 2^53 : take .toInt() to keep
  // typed and survive any future widening
  factory PrekeyBundle.fromJson(Map<String, dynamic> json) {
    final opkJson = json['opk'] as Map<String, dynamic>?;
    return PrekeyBundle(
      userId: json['user_id'] as String,
      ikPub: base64Decode(json['ik_pub'] as String),
      lkPub: base64Decode(json['lk_pub'] as String),
      spkPub: base64Decode(json['spk_pub'] as String),
      spkSig: base64Decode(json['spk_sig'] as String),
      spkTs: (json['spk_ts'] as num).toInt(),
      opk: opkJson == null
          ? null
          : BundleOpk(
              idx: (opkJson['idx'] as num).toInt(),
              keyPub: base64Decode(opkJson['key_pub'] as String),
            ),
    );
  }

  // Order matches D8 : cheapest checks first. ts skew is ±90d
  // §2.3 : direction split into ts_too_old / ts_in_future so the UI can tell
  // a stale server from a maliciously future stamped bundle apart
  Future<void> verify({required Now now}) async {
    if (ikPub.length != 32 ||
        lkPub.length != 32 ||
        spkPub.length != 32 ||
        spkSig.length != 64) {
      throw const BundleVerificationException('length');
    }

    final nowSec = now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final delta = nowSec - spkTs;
    if (delta.abs() > _kTsSkewSeconds) {
      throw BundleVerificationException(
          delta > 0 ? 'ts_too_old' : 'ts_in_future');
    }

    final ok = await Sign.verify(ikPub, _spkSigMsg(spkPub, spkTs), spkSig);
    if (!ok) {
      throw const BundleVerificationException('sig_invalid');
    }
  }
}

class BundleOpk {
  final int idx;
  final Uint8List keyPub;
  const BundleOpk({required this.idx, required this.keyPub});
}

class BundleVerificationException implements Exception {
  // Reason codes : 'length' | 'sig_invalid' | 'ts_too_old' | 'ts_in_future'
  final String reason;
  const BundleVerificationException(this.reason);
  @override
  String toString() => 'BundleVerificationException($reason)';
}

const int _kTsSkewSeconds = 90 * 24 * 3600;

// spk_pub (32) || u64_be(spk_ts) , 40 bytes total : same byte layout as the
// §2.2 spk upload in IdentityService._spkSigMsg
Uint8List _spkSigMsg(Uint8List spkPub, int spkTs) {
  final out = Uint8List(40);
  out.setRange(0, 32, spkPub);
  ByteData.sublistView(out, 32).setUint64(0, spkTs, Endian.big);
  return out;
}
