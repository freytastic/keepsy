import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/x3dh.dart';

import '../_sodium_setup.dart';

// D9 fuzzer : 1000 random key tuples + album_ids, both 4-DH and 3-DH paths,
// asserts initiator/responder byte equal agreement on every iteration.
// Calls X3dh.initiator/responder directly (NOT X3dhSession) bcs the math
// primitive is what needs the fuzz coverage : the session wrapper adds
// IdentityService bootstrap + label resolution that would dominate runtime
// without testing anything new

Future<X25519KeyPair> _randomX25519(Random rng) async {
  // X25519 private scalars are arbitrary 32B blobs : libsodium
  // clamps inside scalarmult per RFC 7748 §5
  final priv = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    priv[i] = rng.nextInt(256);
  }
  return Kex.fromSeed(priv);
}

Uint8List _randomAlbumId(Random rng) {
  final out = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

void main() {
  setUpAll(ensureSodium);

  test('1000 random bundles: initiator and responder agree', () async {
    final rng = Random(42);

    for (var i = 0; i < 1000; i++) {
      final lkA = await _randomX25519(rng);
      final ekA = await _randomX25519(rng);
      final lkB = await _randomX25519(rng);
      final spkB = await _randomX25519(rng);

      final use4dh = i.isEven;
      final opkB = use4dh ? await _randomX25519(rng) : null;
      final albumId = _randomAlbumId(rng);

      final aShared = await X3dh.initiator(
        lkSkA: lkA,
        ekSkA: ekA,
        lkPkB: lkB.publicKey,
        spkPkB: spkB.publicKey,
        opkPkB: opkB?.publicKey,
        albumId: albumId,
      );
      final bShared = await X3dh.responder(
        lkSkB: lkB,
        spkSkB: spkB,
        opkSkB: opkB,
        lkPkA: lkA.publicKey,
        ekPkA: ekA.publicKey,
        albumId: albumId,
      );

      expect(aShared.length, 32);
      expect(aShared, orderedEquals(bShared),
          reason: 'iter=$i path=${use4dh ? "4-DH" : "3-DH"}');
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
