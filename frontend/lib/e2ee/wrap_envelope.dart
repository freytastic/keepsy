import 'dart:convert';
import 'dart:typed_data';

import 'package:keepsy/crypto/wire_format.dart';

// Decoded GET /albums/{id}/epoch/{n}/wrap response. Bytes in / bytes out :
// EpochProcessor pre validates lengths and the VER prefix (verifyShape) before
// any expensive crypto runs

class WrapEnvelope {
  // Total wire wrap length: VER(1) + NONCE(12) + TAG(16) + CT(32) = 61 (§4.1)
  static const int wrapBlobLen = 1 + kNonceLen + kTagLen + 32;

  final int epoch;
  final Uint8List ekPub; // 32B
  final Uint8List wrap; // 61B (VER ‖ NONCE ‖ TAG ‖ CT)
  final Uint8List senderToken; // 32B
  final Uint8List senderSig; // 64B Ed25519
  final int? opkIdxUsed;
  final DateTime deliveredAt;

  const WrapEnvelope({
    required this.epoch,
    required this.ekPub,
    required this.wrap,
    required this.senderToken,
    required this.senderSig,
    required this.opkIdxUsed,
    required this.deliveredAt,
  });

  factory WrapEnvelope.fromJson(Map<String, dynamic> json) {
    return WrapEnvelope(
      epoch: (json['epoch'] as num).toInt(),
      ekPub: base64Decode(json['ek_pub'] as String),
      wrap: base64Decode(json['wrap'] as String),
      senderToken: base64Decode(json['sender_token'] as String),
      senderSig: base64Decode(json['sender_sig'] as String),
      opkIdxUsed: json['opk_idx_used'] == null
          ? null
          : (json['opk_idx_used'] as num).toInt(),
      deliveredAt: DateTime.parse(json['delivered_at'] as String),
    );
  }

  // Cheapest checks first : lengths + VER. Anything heavier (sig, AEAD) runs
  // only after this passes
  void verifyShape() {
    if (ekPub.length != 32 ||
        wrap.length != wrapBlobLen ||
        wrap[0] != kVerAesGcm ||
        senderToken.length != 32 ||
        senderSig.length != 64) {
      throw const WrapVerificationException('length');
    }
  }
}

class WrapVerificationException implements Exception {
  // 'length' | 'sig_invalid' | 'aead_auth_failed'
  final String reason;
  const WrapVerificationException(this.reason);
  @override
  String toString() => 'WrapVerificationException($reason)';
}
