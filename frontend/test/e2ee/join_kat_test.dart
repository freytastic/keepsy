import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/e2ee/join.dart';

import '../_sodium_setup.dart';

const String _katFile = '../server/test_vectors/join_complete_kat.json';

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hexEnc(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  setUpAll(ensureSodium);

  test('join_complete KAT agrees with server fixture byte-for-byte', () async {
    final f = File(_katFile);
    if (!f.existsSync()) {
      // ignore: avoid_print
      print('join_complete_kat.json missing : server lane not yet landed');
      return;
    }
    final kat = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final vectors = (kat['vectors'] as List).cast<Map>();
    expect(vectors, isNotEmpty);

    for (final tv in vectors) {
      final albumId = _hex(tv['album_id_hex'] as String);
      final ek = _hex(tv['ek_pub_admin_hex'] as String);
      final epoch = (tv['epoch'] as num).toInt();
      final expectedMsg = tv['expected_msg_hex'] as String;
      final expectedSig = tv['expected_sig_hex'] as String;

      final msg = joinCompleteMsg(albumId, epoch, ek);
      expect(_hexEnc(msg), expectedMsg,
          reason: '${tv['name']}: join-complete-v1 msg bytes diverged');

      final kp = await Sign.fromSeed(_hex(tv['ik_seed_hex'] as String));
      final sig = await Sign.sign(kp, msg);
      expect(_hexEnc(sig), expectedSig, reason: '${tv['name']}: sig diverged');
      expect(await Sign.verify(kp.publicKey, msg, _hex(expectedSig)), isTrue);
    }
  });
}
