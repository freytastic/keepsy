import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/x3dh.dart';

import '../_sodium_setup.dart';

Future<
    ({
      X25519KeyPair lkA,
      X25519KeyPair ekA,
      X25519KeyPair lkB,
      X25519KeyPair spkB,
      X25519KeyPair opkB
    })> _freshKeys() async {
  return (
    lkA: await Kex.generateX25519(),
    ekA: await Kex.generateX25519(),
    lkB: await Kex.generateX25519(),
    spkB: await Kex.generateX25519(),
    opkB: await Kex.generateX25519(),
  );
}

void main() {
  setUpAll(ensureSodium);

  final albumId = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));

  group('X3DH 4-DH (with OPK)', () {
    test('initiator and responder agree on shared secret', () async {
      final k = await _freshKeys();

      final aShared = await X3dh.initiator(
        lkSkA: k.lkA,
        ekSkA: k.ekA,
        lkPkB: k.lkB.publicKey,
        spkPkB: k.spkB.publicKey,
        opkPkB: k.opkB.publicKey,
        albumId: albumId,
      );
      final bShared = await X3dh.responder(
        lkSkB: k.lkB,
        spkSkB: k.spkB,
        opkSkB: k.opkB,
        lkPkA: k.lkA.publicKey,
        ekPkA: k.ekA.publicKey,
        albumId: albumId,
      );

      expect(aShared.length, equals(32));
      expect(aShared, orderedEquals(bShared));
    });

    test('different album_id breaks agreement (info domain separation)',
        () async {
      final k = await _freshKeys();
      final otherAlbum =
          Uint8List.fromList(List<int>.generate(16, (i) => 0xFF - i));

      final aShared = await X3dh.initiator(
        lkSkA: k.lkA,
        ekSkA: k.ekA,
        lkPkB: k.lkB.publicKey,
        spkPkB: k.spkB.publicKey,
        opkPkB: k.opkB.publicKey,
        albumId: albumId,
      );
      final bShared = await X3dh.responder(
        lkSkB: k.lkB,
        spkSkB: k.spkB,
        opkSkB: k.opkB,
        lkPkA: k.lkA.publicKey,
        ekPkA: k.ekA.publicKey,
        albumId: otherAlbum,
      );

      expect(aShared, isNot(orderedEquals(bShared)));
    });
  });

  group('X3DH 3-DH (OPK exhausted)', () {
    test('initiator and responder agree without OPK', () async {
      final k = await _freshKeys();

      final aShared = await X3dh.initiator(
        lkSkA: k.lkA,
        ekSkA: k.ekA,
        lkPkB: k.lkB.publicKey,
        spkPkB: k.spkB.publicKey,
        albumId: albumId,
      );
      final bShared = await X3dh.responder(
        lkSkB: k.lkB,
        spkSkB: k.spkB,
        lkPkA: k.lkA.publicKey,
        ekPkA: k.ekA.publicKey,
        albumId: albumId,
      );

      expect(aShared, orderedEquals(bShared));
    });

    test('3-DH and 4-DH outputs differ (DH4 affects KM)', () async {
      final k = await _freshKeys();

      final with4 = await X3dh.initiator(
        lkSkA: k.lkA,
        ekSkA: k.ekA,
        lkPkB: k.lkB.publicKey,
        spkPkB: k.spkB.publicKey,
        opkPkB: k.opkB.publicKey,
        albumId: albumId,
      );
      final with3 = await X3dh.initiator(
        lkSkA: k.lkA,
        ekSkA: k.ekA,
        lkPkB: k.lkB.publicKey,
        spkPkB: k.spkB.publicKey,
        albumId: albumId,
      );
      expect(with4, isNot(orderedEquals(with3)));
    });

    test('asymmetric OPK presence (A has OPK, B does not) → disagreement',
        () async {
      final k = await _freshKeys();

      final aShared = await X3dh.initiator(
        lkSkA: k.lkA,
        ekSkA: k.ekA,
        lkPkB: k.lkB.publicKey,
        spkPkB: k.spkB.publicKey,
        opkPkB: k.opkB.publicKey,
        albumId: albumId,
      );
      final bShared = await X3dh.responder(
        lkSkB: k.lkB,
        spkSkB: k.spkB,
        lkPkA: k.lkA.publicKey,
        ekPkA: k.ekA.publicKey,
        albumId: albumId,
      );
      expect(aShared, isNot(orderedEquals(bShared)));
    });
  });

  group('X3DH input validation', () {
    test('rejects wrong-size peer pub', () async {
      final k = await _freshKeys();
      expect(
        () => X3dh.initiator(
          lkSkA: k.lkA,
          ekSkA: k.ekA,
          lkPkB: Uint8List(31), // wrong length
          spkPkB: k.spkB.publicKey,
          albumId: albumId,
        ),
        throwsArgumentError,
      );
    });
  });
}
