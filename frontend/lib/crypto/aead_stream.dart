import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;

import 'primitives.dart';
import 'wire_format.dart';

// VER=0x03 streaming AEAD. Files >= 1 MiB use this format : smaller files
// use VER=0x01 (Aead.encrypt). Wire layout :

//   HEADER : VER(1) ‖ FILE_NONCE(12) ‖ SEGMENT_SIZE_BE(4)            17 B
//   SEGMENT_i : TAG_i(16) ‖ CT_i(<= SEGMENT_SIZE)

// Per segment nonce : HKDF-SHA256(IKM=DEK, salt=FILE_NONCE,
//                                 info=kSaltSegNonce ‖ u32_be(i), L=12)
// Per segment AAD   : media_id(16) ‖ u32_be(i) ‖ u32_be(is_last ? 1 : 0)

// Defenses :
//   - Reorder : segment_index in AAD : swapping segments fails the tag
//   - Truncation : is_last=1 only on the actual final segment : chopping the
//     last segment makes the new "last" fail (its AAD has is_last=0)
//   - Cross file : media_id in AAD : a relabel attempt fails

// (video v2) : current implementation is byte oriented (encryptBytes /
// decryptBytes). For videos up to multi GB the streaming I/O variant
// (Stream<Uint8List> in, IOSink out) keeps the segment math identical but
// avoids loading the whole file into memory. Will add later
abstract class AeadStream {
  static const int headerLen =
      1 + kNonceLen + 4; // VER + FILE_NONCE + SEGMENT_SIZE_BE
  static const int segmentTagLen = kTagLen;

  // EncryptBytes runs the segment loop over an in memory plaintext. mediaId
  // must be exactly 16 bytes (raw UUID). Output is the full wire blob ready
  // to upload. Last segment may be shorter than kSegmentSize (down to 0)
  static Future<Uint8List> encryptBytes({
    required Uint8List dek,
    required Uint8List plaintext,
    required Uint8List mediaId,
  }) async {
    if (dek.length != 32) {
      throw ArgumentError('dek must be 32 bytes, got ${dek.length}');
    }
    if (mediaId.length != 16) {
      throw ArgumentError('mediaId must be 16 bytes, got ${mediaId.length}');
    }
    final fileNonce = Csprng.bytes(kNonceLen);

    final segments = _splitSegments(plaintext.length);
    final out = BytesBuilder(copy: false);

    final header = Uint8List(headerLen);
    header[0] = kVerStreamGcm;
    header.setRange(1, 1 + kNonceLen, fileNonce);
    ByteData.sublistView(header, 1 + kNonceLen, headerLen)
        .setUint32(0, kSegmentSize, Endian.big);
    out.add(header);

    final aes = cg.AesGcm.with256bits();
    for (var i = 0; i < segments; i++) {
      final start = i * kSegmentSize;
      final end = (start + kSegmentSize > plaintext.length)
          ? plaintext.length
          : start + kSegmentSize;
      final isLast = i == segments - 1;
      final segPlain = Uint8List.sublistView(plaintext, start, end);
      final aad = _segmentAad(mediaId, i, isLast);
      final nonce = await _segmentNonce(dek, fileNonce, i);
      final box = await aes.encrypt(
        segPlain,
        secretKey: cg.SecretKey(dek),
        nonce: nonce,
        aad: aad,
      );
      out.add(box.mac.bytes);
      out.add(box.cipherText);
    }
    return out.toBytes();
  }

  // DecryptBytes reverses encryptBytes. Throws AeadAuthFailed on any segment
  // tag failure (tamper, reorder, truncation, AAD mismatch) and FormatException
  // on a malformed header / impossibly short body. mediaId must match what
  // was used at encrypt time
  static Future<Uint8List> decryptBytes({
    required Uint8List dek,
    required Uint8List wire,
    required Uint8List mediaId,
  }) async {
    if (dek.length != 32) {
      throw ArgumentError('dek must be 32 bytes, got ${dek.length}');
    }
    if (mediaId.length != 16) {
      throw ArgumentError('mediaId must be 16 bytes, got ${mediaId.length}');
    }
    if (wire.length < headerLen) {
      throw FormatException(
          'wire too short for VER=0x03 header: ${wire.length} bytes');
    }
    if (wire[0] != kVerStreamGcm) {
      throw FormatException(
          'wire VER byte = 0x${wire[0].toRadixString(16)}, want 0x03');
    }
    final fileNonce = Uint8List.sublistView(wire, 1, 1 + kNonceLen);
    final segmentSize = ByteData.sublistView(wire, 1 + kNonceLen, headerLen)
        .getUint32(0, Endian.big);
    if (segmentSize != kSegmentSize) {
      // Allow other segment sizes only when explicitly migrated. Refuse for now :
      // an attacker re writing the header to inflate the parser is a real risk
      throw FormatException(
          'unexpected segment size: $segmentSize, want $kSegmentSize');
    }

    final body = Uint8List.sublistView(wire, headerLen);
    // encryptBytes always emits >= 1 segment (a 0 byte file still produces one
    // authenticated zero length last segment : 16 byte tag). A header only body
    // authenticates nothing : rejecting it stops a forged "empty" blob from
    // decrypting to empty plaintext without any tag being verified
    if (body.isEmpty) {
      throw FormatException(
          'VER=0x03 blob has no segments: body is empty after header');
    }
    final aes = cg.AesGcm.with256bits();
    final out = BytesBuilder(copy: false);

    var cursor = 0;
    var i = 0;
    while (cursor < body.length) {
      // Each segment frames as TAG(16) + CT(<= segmentSize). Last segment can
      // be shorter : non last must be exactly kSegmentSize bytes of CT
      final remaining = body.length - cursor;
      if (remaining < segmentTagLen) {
        throw FormatException(
            'segment $i truncated: ${remaining}B left, need >= $segmentTagLen');
      }
      final tag = Uint8List.sublistView(body, cursor, cursor + segmentTagLen);
      cursor += segmentTagLen;

      final ctRemaining = body.length - cursor;
      // Detect last segment by "rest of body fits in <= one segment ct"
      final isLast = ctRemaining <= segmentSize;
      final ctLen = isLast ? ctRemaining : segmentSize;
      if (!isLast && ctLen != segmentSize) {
        throw FormatException(
            'segment $i ct length mismatch: $ctLen, want $segmentSize');
      }
      final ct = Uint8List.sublistView(body, cursor, cursor + ctLen);
      cursor += ctLen;

      final aad = _segmentAad(mediaId, i, isLast);
      final nonce = await _segmentNonce(dek, fileNonce, i);
      try {
        final pt = await aes.decrypt(
          cg.SecretBox(ct, nonce: nonce, mac: cg.Mac(tag)),
          secretKey: cg.SecretKey(dek),
          aad: aad,
        );
        out.add(pt);
      } on cg.SecretBoxAuthenticationError catch (e) {
        throw AeadAuthFailed('segment $i: ${e.toString()}');
      }

      i++;
    }
    return out.toBytes();
  }

  // _splitSegments returns the number of segments needed to cover plaintextLen
  // bytes. Always >= 1 (a 0 byte file produces one zero length last segment :
  // the AAD is_last=1 marker still authenticates the empty payload)
  static int _splitSegments(int plaintextLen) {
    if (plaintextLen == 0) return 1;
    return (plaintextLen + kSegmentSize - 1) ~/ kSegmentSize;
  }

  static Uint8List _segmentAad(Uint8List mediaId, int index, bool isLast) {
    // 16 (media_id) + 4 (u32_be index) + 4 (u32_be is_last) = 24 bytes
    final out = Uint8List(16 + 4 + 4);
    out.setRange(0, 16, mediaId);
    final view = ByteData.sublistView(out);
    view.setUint32(16, index, Endian.big);
    view.setUint32(20, isLast ? 1 : 0, Endian.big);
    return out;
  }

  static Future<Uint8List> _segmentNonce(
      Uint8List dek, Uint8List fileNonce, int index) async {
    // info = kSaltSegNonce ‖ u32_be(index)
    final info = Uint8List(kSaltSegNonce.length + 4);
    info.setRange(0, kSaltSegNonce.length, kSaltSegNonce);
    ByteData.sublistView(info, kSaltSegNonce.length)
        .setUint32(0, index, Endian.big);
    return Hkdf.derive(
      ikm: dek,
      salt: fileNonce,
      info: info,
      length: kNonceLen,
    );
  }
}
