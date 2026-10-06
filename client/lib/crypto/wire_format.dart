import 'dart:typed_data';

// Wire format version bytes (D5). Mirrored in internal/crypto/wire_format.go
const int kVerAesGcm = 0x01;
const int kVerChaPo = 0x02;
const int kVerStreamGcm = 0x03;

// Segment size for VER=0x03 streaming AEAD: 1 MiB (L2)
const int kSegmentSize = 1 << 20;

// Length constants for X3DH info construction (L1)
const int kIkPubLen = 32;
const int kLkPubLen = 32;
const int kAlbumIdLen = 16;
const int kX3dhInfoLen = kLkPubLen + kLkPubLen + kAlbumIdLen;

// Domain separation salts (L9). Mirrored byte-for-byte in internal/crypto/salts.go
// All values are pure ASCII : codeUnits equal UTF-8 bytes here
final Uint8List kSaltX3dh = Uint8List.fromList('vault-x3dh-v1'.codeUnits);
final Uint8List kSaltInvite = Uint8List.fromList('invite-v1'.codeUnits);
final Uint8List kSaltSegNonce = Uint8List.fromList('seg-nonce-v1'.codeUnits);
final Uint8List kSaltKeyConfirm =
    Uint8List.fromList('key-confirm-v1'.codeUnits);
final Uint8List kSaltManifest = Uint8List.fromList('manifest-v1'.codeUnits);
final Uint8List kSaltSpkRotate = Uint8List.fromList('rotate-spk-v1'.codeUnits);
final Uint8List kSaltPromote = Uint8List.fromList('promote-v1'.codeUnits);
final Uint8List kSaltJoinComplete =
    Uint8List.fromList('join-complete-v1'.codeUnits);
final Uint8List kSaltAlbumNameHint =
    Uint8List.fromList('album-name-v1'.codeUnits);

// Builds the X3DH HKDF info string per L1: LK_pub_A || LK_pub_B || album_id
// Uses LK_pub (X25519 keys actually used in DH1), not IK_pub (Ed25519 : would
// silently produce wrong DH output if passed to X25519)
Uint8List kX3dhInfoConstruction(
    Uint8List lkPubA, Uint8List lkPubB, Uint8List albumId) {
  if (lkPubA.length != kLkPubLen) {
    throw ArgumentError(
        'lkPubA must be $kLkPubLen bytes, got ${lkPubA.length}');
  }
  if (lkPubB.length != kLkPubLen) {
    throw ArgumentError(
        'lkPubB must be $kLkPubLen bytes, got ${lkPubB.length}');
  }
  if (albumId.length != kAlbumIdLen) {
    throw ArgumentError(
        'albumId must be $kAlbumIdLen bytes (raw UUID), got ${albumId.length}');
  }
  final out = Uint8List(kX3dhInfoLen);
  out.setRange(0, kLkPubLen, lkPubA);
  out.setRange(kLkPubLen, 2 * kLkPubLen, lkPubB);
  out.setRange(2 * kLkPubLen, kX3dhInfoLen, albumId);
  return out;
}

// Wire format byte layout: VER(1) || NONCE(12) || TAG(16) || CT(N)
// VER selects the AEAD algorithm : anything that picks an algorithm from
// somewhere other than this byte is a bug (D5)
const int kNonceLen = 12;
const int kTagLen = 16;
const int kHeaderLen = 1 + kNonceLen + kTagLen;

class ParsedWire {
  final int version;
  final Uint8List nonce;
  final Uint8List tag;
  final Uint8List ciphertext;
  const ParsedWire({
    required this.version,
    required this.nonce,
    required this.tag,
    required this.ciphertext,
  });
}

abstract class WireFormat {
  // Parses VER(1) || NONCE(12) || TAG(16) || CT(N)
  // Throws FormatException on under-length input or unknown VER byte
  // VER=0x03 parses successfully, but Aead.decrypt rejects it bcs the
  // streaming format requires a different framing (segments) which is handled in p5
  static ParsedWire parse(Uint8List wire) {
    if (wire.length < kHeaderLen) {
      throw FormatException(
          'wire too short: ${wire.length} bytes, need >= $kHeaderLen');
    }
    final version = wire[0];
    if (version != kVerAesGcm &&
        version != kVerChaPo &&
        version != kVerStreamGcm) {
      throw FormatException(
          'unknown VER byte: 0x${version.toRadixString(16).padLeft(2, '0')}');
    }
    return ParsedWire(
      version: version,
      nonce: Uint8List.sublistView(wire, 1, 1 + kNonceLen),
      tag: Uint8List.sublistView(wire, 1 + kNonceLen, kHeaderLen),
      ciphertext: Uint8List.sublistView(wire, kHeaderLen),
    );
  }

  /// Assembles VER || NONCE || TAG || CT into a single byte array
  static Uint8List assemble({
    required int version,
    required Uint8List nonce,
    required Uint8List tag,
    required Uint8List ciphertext,
  }) {
    if (version != kVerAesGcm &&
        version != kVerChaPo &&
        version != kVerStreamGcm) {
      throw ArgumentError(
          'unknown VER: 0x${version.toRadixString(16).padLeft(2, '0')}');
    }
    if (nonce.length != kNonceLen) {
      throw ArgumentError(
          'nonce must be $kNonceLen bytes, got ${nonce.length}');
    }
    if (tag.length != kTagLen) {
      throw ArgumentError('tag must be $kTagLen bytes, got ${tag.length}');
    }
    final out = Uint8List(kHeaderLen + ciphertext.length);
    out[0] = version;
    out.setRange(1, 1 + kNonceLen, nonce);
    out.setRange(1 + kNonceLen, kHeaderLen, tag);
    out.setRange(kHeaderLen, out.length, ciphertext);
    return out;
  }
}
