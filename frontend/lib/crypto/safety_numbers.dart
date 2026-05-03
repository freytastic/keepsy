import 'dart:typed_data';
import 'package:cryptography/cryptography.dart' as cg;
import 'wire_format.dart';

// Pairwise safety number for MITM detection

//   SafetyNumber(A, B) =
//     first 30 decimal digits of :
//       SHA256(SORT_LEXICOGRAPHIC(IK_pub_A, IK_pub_B) || album_id)
//     formatted as: XXXXX XXXXX XXXXX XXXXX XXXXX XXXXX

// IKs are the Ed25519 32-byte identity keys. The sort makes the function
// symmetric : both A and B compute the same number for a given album
class SafetyNumber {
  static const int totalDigits = 30;
  static const int groupSize = 5;

  // Returns the unformatted 30 digit string (no spaces)
  static Future<String> compute({
    required Uint8List ikPubA,
    required Uint8List ikPubB,
    required Uint8List albumId,
  }) async {
    if (ikPubA.length != kIkPubLen) {
      throw ArgumentError(
          'ikPubA must be $kIkPubLen bytes, got ${ikPubA.length}');
    }
    if (ikPubB.length != kIkPubLen) {
      throw ArgumentError(
          'ikPubB must be $kIkPubLen bytes, got ${ikPubB.length}');
    }
    if (albumId.length != kAlbumIdLen) {
      throw ArgumentError(
          'albumId must be $kAlbumIdLen bytes, got ${albumId.length}');
    }

    final lo = _lex(ikPubA, ikPubB) <= 0 ? ikPubA : ikPubB;
    final hi = _lex(ikPubA, ikPubB) <= 0 ? ikPubB : ikPubA;

    final preimage = Uint8List(kIkPubLen + kIkPubLen + kAlbumIdLen);
    preimage.setRange(0, kIkPubLen, lo);
    preimage.setRange(kIkPubLen, 2 * kIkPubLen, hi);
    preimage.setRange(2 * kIkPubLen, preimage.length, albumId);

    final hash = await cg.Sha256().hash(preimage);
    return _firstNDecimalDigits(Uint8List.fromList(hash.bytes), totalDigits);
  }

  // Returns the formatted "XXXXX XXXXX XXXXX XXXXX XXXXX XXXXX"
  static Future<String> formatted({
    required Uint8List ikPubA,
    required Uint8List ikPubB,
    required Uint8List albumId,
  }) async {
    final digits =
        await compute(ikPubA: ikPubA, ikPubB: ikPubB, albumId: albumId);
    return _group(digits);
  }

  static int _lex(Uint8List a, Uint8List b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  // SHA-256 (32 bytes, BE) is < 10^78. Format as a 78-char zero-padded decimal
  // string and slice the first n. This makes "first 30 decimal digits" a fixed
  // positional contract regardless of whether the hash's leading byte is zero
  static String _firstNDecimalDigits(Uint8List digest, int n) {
    // Big-endian → BigInt
    BigInt v = BigInt.zero;
    for (final b in digest) {
      v = (v << 8) | BigInt.from(b);
    }
    const int totalLen = 78; // 2^256 < 10^78
    final s = v.toString().padLeft(totalLen, '0');
    return s.substring(0, n);
  }

  static String _group(String digits) {
    final groups = <String>[];
    for (var i = 0; i < digits.length; i += groupSize) {
      groups.add(digits.substring(
          i, i + groupSize > digits.length ? digits.length : i + groupSize));
    }
    return groups.join(' ');
  }
}
