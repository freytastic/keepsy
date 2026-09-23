import 'dart:typed_data';

import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/e2ee/album_keys.dart';

typedef AadForEpoch = Uint8List Function(int epoch);

// Small secrets sealed under one album epoch's MK. Members keep every epoch's
// MK, so the epoch travels in the blob and old blobs open after rotation
//   wire = u32_be(epoch) || VER || NONCE || TAG || CT
abstract class MkSeal {
  static Future<Uint8List> seal(AlbumKeyStore ks, Uint8List albumId, int epoch,
      Uint8List plaintext, AadForEpoch aadFor) async {
    if (epoch < 0) throw ArgumentError('epoch must be >= 0, got $epoch');
    final blob = await ks.useMk<Uint8List>(
        albumId,
        epoch,
        (mk) => Aead.encrypt(
            version: kVerAesGcm,
            key: mk,
            plaintext: plaintext,
            aad: aadFor(epoch)));
    final out = Uint8List(4 + blob.length);
    ByteData.sublistView(out, 0, 4).setUint32(0, epoch, Endian.big);
    out.setRange(4, out.length, blob);
    return out;
  }

  // Null on a malformed blob, a missing MK for its epoch, or an auth failure
  static Future<Uint8List?> open(AlbumKeyStore ks, Uint8List albumId,
      Uint8List wire, AadForEpoch aadFor) async {
    final epoch = epochOf(wire);
    if (epoch == null) return null;
    try {
      return await ks.useMk<Uint8List?>(albumId, epoch, (mk) async {
        try {
          return await Aead.decrypt(
              wire: body(wire), key: mk, aad: aadFor(epoch));
        } on AeadAuthFailed {
          return null;
        } on FormatException {
          return null;
        }
      });
    } catch (_) {
      return null;
    }
  }

  static int? epochOf(Uint8List wire) {
    if (wire.length < 4) return null;
    return ByteData.sublistView(wire, 0, 4).getUint32(0, Endian.big);
  }

  static Uint8List body(Uint8List wire) => Uint8List.sublistView(wire, 4);
}
