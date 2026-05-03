import 'dart:typed_data';
import 'package:cryptography/cryptography.dart' as cg;
import 'primitives.dart';
import 'wire_format.dart';

// X3DH key agreement (4 DH with OPK, 3 DH fallback when OPK exhausted)

// Inputs are all X25519 keys, never IK (Ed25519). Passing an Ed25519 key here
// would silently produce wrong DH output : the explicit type guards in
// Kex.dh + cg.SimplePublicKey(type: x25519) catch this at runtime

//   A computes: DH1=X25519(LK_a, SPK_b)  DH2=X25519(EK_a, LK_b)
//               DH3=X25519(EK_a, SPK_b)  DH4=X25519(EK_a, OPK_b)
//   B mirrors:  DH1=X25519(SPK_b, LK_a)  DH2=X25519(LK_b, EK_a)
//               DH3=X25519(SPK_b, EK_a)  DH4=X25519(OPK_b, EK_a)
//   KM = DH1 || DH2 || DH3 || DH4   (160 bytes, or 128 if no OPK)
//   shared = HKDF-SHA256(IKM=KM, salt=kSaltX3dh,
//                        info=LK_pub_A || LK_pub_B || album_id, length=32)
abstract class X3dh {
  static const int sharedSecretLen = 32;

  static Future<Uint8List> initiator({
    required cg.SimpleKeyPair lkSkA,
    required cg.SimpleKeyPair ekSkA,
    required cg.SimplePublicKey lkPkB,
    required cg.SimplePublicKey spkPkB,
    cg.SimplePublicKey? opkPkB,
    required Uint8List albumId,
  }) async {
    _requireX25519(lkPkB, 'lkPkB');
    _requireX25519(spkPkB, 'spkPkB');
    if (opkPkB != null) _requireX25519(opkPkB, 'opkPkB');

    final dh1 = await Kex.dh(lkSkA, spkPkB);
    final dh2 = await Kex.dh(ekSkA, lkPkB);
    final dh3 = await Kex.dh(ekSkA, spkPkB);
    final dh4 = opkPkB == null ? null : await Kex.dh(ekSkA, opkPkB);

    final lkPkA = await lkSkA.extractPublicKey();
    return _finish(
      dh1: dh1,
      dh2: dh2,
      dh3: dh3,
      dh4: dh4,
      lkPubA: Uint8List.fromList(lkPkA.bytes),
      lkPubB: Uint8List.fromList(lkPkB.bytes),
      albumId: albumId,
    );
  }

  static Future<Uint8List> responder({
    required cg.SimpleKeyPair lkSkB,
    required cg.SimpleKeyPair spkSkB,
    cg.SimpleKeyPair? opkSkB,
    required cg.SimplePublicKey lkPkA,
    required cg.SimplePublicKey ekPkA,
    required Uint8List albumId,
  }) async {
    _requireX25519(lkPkA, 'lkPkA');
    _requireX25519(ekPkA, 'ekPkA');

    final dh1 = await Kex.dh(spkSkB, lkPkA);
    final dh2 = await Kex.dh(lkSkB, ekPkA);
    final dh3 = await Kex.dh(spkSkB, ekPkA);
    final dh4 = opkSkB == null ? null : await Kex.dh(opkSkB, ekPkA);

    final lkPkB = await lkSkB.extractPublicKey();
    return _finish(
      dh1: dh1,
      dh2: dh2,
      dh3: dh3,
      dh4: dh4,
      lkPubA: Uint8List.fromList(lkPkA.bytes),
      lkPubB: Uint8List.fromList(lkPkB.bytes),
      albumId: albumId,
    );
  }

  static Future<Uint8List> _finish({
    required Uint8List dh1,
    required Uint8List dh2,
    required Uint8List dh3,
    required Uint8List? dh4,
    required Uint8List lkPubA,
    required Uint8List lkPubB,
    required Uint8List albumId,
  }) async {
    final km = _concat([dh1, dh2, dh3, if (dh4 != null) dh4]);
    final info = kX3dhInfoConstruction(lkPubA, lkPubB, albumId);
    return Hkdf.derive(
      ikm: km,
      salt: kSaltX3dh,
      info: info,
      length: sharedSecretLen,
    );
  }

  static void _requireX25519(cg.SimplePublicKey pk, String name) {
    if (pk.type != cg.KeyPairType.x25519) {
      throw ArgumentError(
          '$name must be X25519, got ${pk.type} : never pass IK (Ed25519)');
    }
    if (pk.bytes.length != kLkPubLen) {
      throw ArgumentError(
          '$name must be $kLkPubLen bytes, got ${pk.bytes.length}');
    }
  }

  static Uint8List _concat(List<Uint8List> parts) {
    var total = 0;
    for (final p in parts) {
      total += p.length;
    }
    final out = Uint8List(total);
    var off = 0;
    for (final p in parts) {
      out.setRange(off, off + p.length, p);
      off += p.length;
    }
    return out;
  }
}
