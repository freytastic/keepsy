import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:cryptography/cryptography.dart' as cg;
import 'package:keepsy/crypto/x3dh.dart';

Future<cg.SimplePublicKey> _pub(cg.SimpleKeyPair kp) async =>
    await kp.extractPublicKey() as cg.SimplePublicKey;

Future<
    ({
      cg.SimpleKeyPair lkA,
      cg.SimpleKeyPair ekA,
      cg.SimpleKeyPair lkB,
      cg.SimpleKeyPair spkB,
      cg.SimpleKeyPair opkB
    })> _freshKeys() async {
  return (
    lkA: await cg.X25519().newKeyPair(),
    ekA: await cg.X25519().newKeyPair(),
    lkB: await cg.X25519().newKeyPair(),
    spkB: await cg.X25519().newKeyPair(),
    opkB: await cg.X25519().newKeyPair(),
  );
}

void main() {
  final albumId = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));

  group('X3DH 4-DH (with OPK)', () {
    test('initiator and responder agree on shared secret', () async {
      final k = await _freshKeys();

      final aShared = await X3dh.initiator(
        lkSkA: k.lkA,
        ekSkA: k.ekA,
        lkPkB: await _pub(k.lkB),
        spkPkB: await _pub(k.spkB),
        opkPkB: await _pub(k.opkB),
        albumId: albumId,
      );
      final bShared = await X3dh.responder(
        lkSkB: k.lkB,
        spkSkB: k.spkB,
        opkSkB: k.opkB,
        lkPkA: await _pub(k.lkA),
        ekPkA: await _pub(k.ekA),
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
        lkPkB: await _pub(k.lkB),
        spkPkB: await _pub(k.spkB),
        opkPkB: await _pub(k.opkB),
        albumId: albumId,
      );
      final bShared = await X3dh.responder(
        lkSkB: k.lkB,
        spkSkB: k.spkB,
        opkSkB: k.opkB,
        lkPkA: await _pub(k.lkA),
        ekPkA: await _pub(k.ekA),
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
        lkPkB: await _pub(k.lkB),
        spkPkB: await _pub(k.spkB),
        // omit opkPkB
        albumId: albumId,
      );
      final bShared = await X3dh.responder(
        lkSkB: k.lkB,
        spkSkB: k.spkB,
        // omit opkSkB
        lkPkA: await _pub(k.lkA),
        ekPkA: await _pub(k.ekA),
        albumId: albumId,
      );

      expect(aShared, orderedEquals(bShared));
    });

    test('3-DH and 4-DH outputs differ (DH4 affects KM)', () async {
      final k = await _freshKeys();

      final with4 = await X3dh.initiator(
        lkSkA: k.lkA,
        ekSkA: k.ekA,
        lkPkB: await _pub(k.lkB),
        spkPkB: await _pub(k.spkB),
        opkPkB: await _pub(k.opkB),
        albumId: albumId,
      );
      final with3 = await X3dh.initiator(
        lkSkA: k.lkA,
        ekSkA: k.ekA,
        lkPkB: await _pub(k.lkB),
        spkPkB: await _pub(k.spkB),
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
        lkPkB: await _pub(k.lkB),
        spkPkB: await _pub(k.spkB),
        opkPkB: await _pub(k.opkB),
        albumId: albumId,
      );
      final bShared = await X3dh.responder(
        lkSkB: k.lkB,
        spkSkB: k.spkB,
        // B omits opkSkB
        lkPkA: await _pub(k.lkA),
        ekPkA: await _pub(k.ekA),
        albumId: albumId,
      );
      expect(aShared, isNot(orderedEquals(bShared)));
    });
  });

  group('X3DH input validation', () {
    test('rejects Ed25519 key passed where X25519 expected', () async {
      final k = await _freshKeys();
      final ed = await cg.Ed25519().newKeyPair();
      final edPk = await ed.extractPublicKey() as cg.SimplePublicKey;
      final spkPk = await _pub(k.spkB);

      expect(
        () => X3dh.initiator(
          lkSkA: k.lkA,
          ekSkA: k.ekA,
          lkPkB: edPk, // wrong curve
          spkPkB: spkPk,
          albumId: albumId,
        ),
        throwsArgumentError,
      );
    });

    test('rejects wrong-size album_id', () async {
      final k = await _freshKeys();
      final lkPkB = await _pub(k.lkB);
      final spkPkB = await _pub(k.spkB);
      expect(
        () => X3dh.initiator(
          lkSkA: k.lkA,
          ekSkA: k.ekA,
          lkPkB: lkPkB,
          spkPkB: spkPkB,
          albumId: Uint8List(15),
        ),
        throwsArgumentError,
      );
    });
  });
}
