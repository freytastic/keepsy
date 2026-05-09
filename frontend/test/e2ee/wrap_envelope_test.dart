import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/wrap_envelope.dart';

Map<String, dynamic> _validJson() {
  // 0x01 ‖ 12B nonce ‖ 16B tag ‖ 32B ct = 61B
  final wrap = Uint8List(61);
  wrap[0] = 0x01;
  for (var i = 1; i < 61; i++) {
    wrap[i] = i;
  }
  return {
    'epoch': 7,
    'ek_pub': base64Encode(Uint8List(32)),
    'wrap': base64Encode(wrap),
    'sender_token': base64Encode(Uint8List(32)),
    'sender_sig': base64Encode(Uint8List(64)),
    'opk_idx_used': 3,
    'delivered_at': '2026-05-07T12:00:00Z',
  };
}

void main() {
  group('WrapEnvelope.fromJson', () {
    test('round trips a valid response', () {
      final env = WrapEnvelope.fromJson(_validJson());
      expect(env.epoch, 7);
      expect(env.ekPub.length, 32);
      expect(env.wrap.length, 61);
      expect(env.wrap[0], 0x01);
      expect(env.senderToken.length, 32);
      expect(env.senderSig.length, 64);
      expect(env.opkIdxUsed, 3);
      env.verifyShape(); // does not throw
    });
  });

  group('WrapEnvelope.verifyShape', () {
    test('rejects wrong length / bad VER', () {
      // ek_pub too short
      final j1 = _validJson()..['ek_pub'] = base64Encode(Uint8List(31));
      expect(() => WrapEnvelope.fromJson(j1).verifyShape(),
          throwsA(isA<WrapVerificationException>()));

      // wrap too short
      final j2 = _validJson()..['wrap'] = base64Encode(Uint8List(60));
      expect(() => WrapEnvelope.fromJson(j2).verifyShape(),
          throwsA(isA<WrapVerificationException>()));

      // wrap right length but wrong VER byte
      final badWrap = Uint8List(61)..[0] = 0x02;
      final j3 = _validJson()..['wrap'] = base64Encode(badWrap);
      expect(() => WrapEnvelope.fromJson(j3).verifyShape(),
          throwsA(isA<WrapVerificationException>()));

      // sender_sig wrong length
      final j4 = _validJson()..['sender_sig'] = base64Encode(Uint8List(63));
      expect(() => WrapEnvelope.fromJson(j4).verifyShape(),
          throwsA(isA<WrapVerificationException>()));
    });
  });
}
