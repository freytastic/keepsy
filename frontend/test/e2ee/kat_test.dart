import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';

import '../_sodium_setup.dart';

// Cross language KAT: rotate-spk-v1
// Sibling lane (Lane A6) emits server/test_vectors/spk_rotate_kat.json. The
// fixture is a hard contract : if the file is missing the test fails so a
// silently broken cross-lane agreement can't sneak past
const String _katFile = '../server/test_vectors/spk_rotate_kat.json';

Uint8List _hex(String s) {
  if (s.length % 2 != 0) {
    throw FormatException('odd hex length: ${s.length}');
  }
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hexEncode(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _rotationMsg(Uint8List spkPub, int spkTs) {
  final salt = kSaltSpkRotate;
  final out = Uint8List(salt.length + 32 + 8);
  out.setRange(0, salt.length, salt);
  out.setRange(salt.length, salt.length + 32, spkPub);
  ByteData.sublistView(out, salt.length + 32).setUint64(0, spkTs, Endian.big);
  return out;
}

void main() {
  setUpAll(ensureSodium);

  test('rotate-spk-v1 message construction matches §4.2 byte layout', () async {
    // Hand rolled placeholder vector : ik_seed, spk_pub, spk_ts deterministic
    final ikSeed = Uint8List.fromList(List.filled(32, 0xA1));
    final spkPub = Uint8List.fromList(List.filled(32, 0xB2));
    const spkTs = 1714838400;

    // Build msg in Dart and confirm it has the locked bytes
    final msg = _rotationMsg(spkPub, spkTs);
    expect(msg.length, 13 + 32 + 8);
    expect(utf8.decode(msg.sublist(0, 13)), 'rotate-spk-v1');
    expect(msg.sublist(13, 45), spkPub);
    // u64_be(1714838400) = 00 00 00 00 66 36 5b 80
    expect(msg.sublist(45),
        Uint8List.fromList([0x00, 0x00, 0x00, 0x00, 0x66, 0x36, 0x5b, 0x80]));

    // Sign + verify under the IK seed. Proves Dart's Ed25519 sees the same
    // bytes Go's ed25519.Sign will see for the same inputs
    final ikKp = await Sign.fromSeed(ikSeed);
    final sig = await Sign.sign(ikKp, msg);
    expect(await Sign.verify(ikKp.publicKey, msg, sig), isTrue);
  });

  test('cross-language KAT (must agree with server fixture byte-for-byte)',
      () async {
    final f = File(_katFile);
    expect(f.existsSync(), isTrue,
        reason:
            'KAT fixture missing at $_katFile : Lane A6 (cmd/genspkrotatekat) '
            'must run before this test');
    final kat = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final vectors = (kat['vectors'] as List).cast<Map>();
    expect(vectors, isNotEmpty);

    for (final tv in vectors) {
      final ikSeed = _hex(tv['ik_seed'] as String);
      final spkPub = _hex(tv['spk_pub'] as String);
      final spkTs = tv['spk_ts'] as int;
      final expectedMsg = _hex(tv['expected_msg'] as String);
      final expectedSig = _hex(tv['expected_rotation_sig'] as String);

      final msg = _rotationMsg(spkPub, spkTs);
      expect(_hexEncode(msg), _hexEncode(expectedMsg),
          reason: '${tv['name']}: rotate-spk-v1 msg bytes diverged');

      final ikKp = await Sign.fromSeed(ikSeed);
      expect(await Sign.verify(ikKp.publicKey, expectedMsg, expectedSig), isTrue,
          reason: '${tv['name']}: expected_rotation_sig failed Ed25519.verify');
    }
  });
}
