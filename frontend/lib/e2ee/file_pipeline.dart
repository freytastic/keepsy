import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:image/image.dart' as img;
import 'package:keepsy/crypto/aead_stream.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:uuid/uuid.dart';

import 'album_keys.dart';

// File encryption pipeline (§5.1). Per file DEK + algorithm select by plaintext
// size. Photos work now : videos slot in unchanged when the v2 picker / player
// land (the encryption format already handles any size via VER=0x03 segments)

// (video v2) : prepareUpload reads the whole plaintext into memory. For
// multi GB videos add a streaming I/O variant (Stream<Uint8List> in, IOSink
// out) : the AeadStream segment math stays identical

// (M11) : pad ciphertext to size buckets (50 KB / 500 KB / 5 MB / 50 MB)
// before upload so blob_size only reveals the bucket. Leave the precise
// blob_sha256 alone : it must match the actual uploaded bytes for S3 to accept

const int _wrapNonceLen = 12;
const int _wrapTagCTLen = 48; // 16 tag + 32 ct(DEK)
const int _wrapWireLen = 1 + _wrapNonceLen + _wrapTagCTLen; // 61
const int _dekLen = 32;
const int _mediaIdLen = 16;

//  thumb is max 400px long edge, JPEG q=70 (i thought of WebP but
// package:image 4.8 has no encodeWebP : JPEG hits the ~20KB target close
// enough). Encoded as image/webp on the wire would be nice future swap
const int _thumbMaxDim = 400;
const int _thumbJpegQuality = 70;
// "thumb" suffix bound into thumb cipher AAD so it cant be swapped with a
// file blob from the same media_id
final Uint8List _kThumbAadSuffix = Uint8List.fromList('thumb'.codeUnits);

// A photo we could not decode, so we cannot guarantee its metadata was
// stripped. Fail closed rather than upload the original bytes (EXIF/GPS intact)
class UnprocessableImageException implements Exception {
  final String message;
  const UnprocessableImageException(this.message);
  @override
  String toString() => 'UnprocessableImageException($message)';
}

class UploadEnvelope {
  final Uint8List mediaId; // 16B raw UUID
  final Uint8List
      cipherBytes; // full wire (VER=0x01 single tag OR VER=0x03 stream)
  final Uint8List wrapNonce; // 12B
  final Uint8List wrapTagCT; // 48B (TAG ‖ AES-GCM(MK, DEK))
  final int epoch;
  final int blobSize;
  final Uint8List blobSha256; // 32B
  final String mediaType; // 'photo' or 'video'
  final String? mimeType;
  // thumb is its own DEK + cipher + wrap. Null for videos (no thumb codec
  // yet) : an undecodable photo fails closed upstream, so any accepted photo
  // has a thumb
  final Uint8List? thumbCipherBytes;
  final Uint8List? thumbWrapNonce;
  final Uint8List? thumbWrapTagCT;
  final Uint8List? thumbSha256;
  // Cleartext bytes carried alongside the wire for the post upload cache
  // seed : the uploader already has the plaintext in memory, no reason to
  // pay an L3 fetch + decrypt to render their own freshly uploaded grid
  // tile. These DO NOT i repeat soldier DO NOT touch disk (L1 RAM only)
  final Uint8List filePlaintext;
  final Uint8List? thumbPlaintext;

  const UploadEnvelope({
    required this.mediaId,
    required this.cipherBytes,
    required this.wrapNonce,
    required this.wrapTagCT,
    required this.epoch,
    required this.blobSize,
    required this.blobSha256,
    required this.mediaType,
    required this.mimeType,
    required this.filePlaintext,
    this.thumbCipherBytes,
    this.thumbWrapNonce,
    this.thumbWrapTagCT,
    this.thumbSha256,
    this.thumbPlaintext,
  });

  bool get hasThumb => thumbCipherBytes != null;
  int get thumbSize => thumbCipherBytes?.length ?? 0;

  // String form of the media_id for endpoints that take it in JSON. The raw
  // 16 byte form stays in 'mediaId' since AAD construction needs the bytes
  String get mediaIdString => _uuidStringFromBytes(mediaId);
}

abstract class FilePipeline {
  // PrepareUpload generates a fresh DEK, encrypts plaintext under it (VER
  // selected by size), wraps the DEK under MK_current of (albumId, epoch),
  // and returns everything the upload step needs. The DEK is zeroed before
  // return : nothing in the returned envelope can decrypt the cipher without
  // unwrapping the DEK first
  static Future<UploadEnvelope> prepareUpload({
    required AlbumKeyStore aks,
    required Uint8List albumIdBytes,
    required int currentEpoch,
    required Uint8List plaintext,
    required String mediaType,
    String? mimeType,
  }) async {
    if (albumIdBytes.length != _mediaIdLen) {
      throw ArgumentError(
          'albumIdBytes must be 16 bytes, got ${albumIdBytes.length}');
    }
    if (mediaType != 'photo' && mediaType != 'video') {
      throw ArgumentError(
          "mediaType must be 'photo' or 'video', got $mediaType");
    }

    final mediaId = _newUuidBytes();
    final dek = Csprng.bytes(_dekLen);

    try {
      // for photos, decode + re encode as a fresh JPEG with EXIF explicitly
      // cleared (see _stripExifAndThumb : decoding alone does NOT drop it), and
      // pull a 400px thumbnail off the same decoded image so we dont decode
      // twice. A photo we cant decode fails closed below (we wont upload raw
      // bytes with metadata intact). Videos keep the raw path : no image codec
      Uint8List bytesToEncrypt = plaintext;
      Uint8List? thumbPlaintext;
      if (mediaType == 'photo') {
        final stripped = _stripExifAndThumb(plaintext);
        // Fail closed : if we couldnt decode the photo we cant guarantee its
        // metadata was stripped, so we refuse rather than upload the original
        // bytes with EXIF/GPS intact (video keeps the raw path : no image codec)
        if (stripped == null) {
          throw const UnprocessableImageException(
              'photo could not be decoded to strip metadata');
        }
        bytesToEncrypt = stripped.cleanJpeg;
        thumbPlaintext = stripped.thumb;
      }

      // Algorithm select by plaintext size only (D5) : <1 MiB → VER=0x01
      // single tag, >=1 MiB → VER=0x03 streaming. Anything that picks an
      // algorithm from anywhere other than this size check is a bug
      Uint8List cipher;
      if (bytesToEncrypt.length < kSegmentSize) {
        cipher = await Aead.encrypt(
          version: kVerAesGcm,
          key: dek,
          plaintext: bytesToEncrypt,
          aad: mediaId,
        );
      } else {
        cipher = await AeadStream.encryptBytes(
          dek: dek,
          plaintext: bytesToEncrypt,
          mediaId: mediaId,
        );
      }

      final blobSha256 = await _sha256(cipher);

      final wrapAad = _wrapAad(albumIdBytes, currentEpoch);

      // thumb has its OWN DEK so MK compromise doesnt leak thumb + file
      // together. Thumb cipher AAD = media_id ‖ "thumb" so a swapped thumb
      // object from the same media_id fails the AEAD tag. The thumb cipher
      // needs no MK, so encrypt it before we touch the keystore
      final Uint8List? dekThumb =
          thumbPlaintext == null ? null : Csprng.bytes(_dekLen);
      Uint8List? thumbCipher;
      Uint8List? thumbWrapNonce;
      Uint8List? thumbWrapTagCT;
      Uint8List? thumbSha256;

      // dekThumb + the MK wraps all are under one try/finally so the thumb DEK
      // is zeroed even if the thumb encrypt/hash or a wrap throws. Both DEK
      // wraps run INSIDE one useMk callback : the MK bytes never escape it
      // (SecureKeyStore.use zeroes them in finally : see the album_keys "zeroes
      // the buffer in finally" test) and we still hit the keystore MethodChannel
      // a single time per upload (platform thread thrash matters more than ms
      // here : see project_post_libsodium_bottleneck)
      late final Uint8List wrapNonce;
      late final Uint8List wrapTagCT;
      try {
        if (dekThumb != null) {
          thumbCipher = await Aead.encrypt(
            version: kVerAesGcm,
            key: dekThumb,
            plaintext: thumbPlaintext!,
            aad: _thumbAad(mediaId),
          );
          thumbSha256 = await _sha256(thumbCipher);
        }
        await aks.useMk<void>(albumIdBytes, currentEpoch, (mk) async {
          final wrapWire = await Aead.encrypt(
            version: kVerAesGcm,
            key: mk,
            plaintext: dek,
            aad: wrapAad,
          );
          if (wrapWire.length != _wrapWireLen) {
            throw StateError(
                'wrap wire length = ${wrapWire.length}, want $_wrapWireLen');
          }
          wrapNonce =
              Uint8List.fromList(wrapWire.sublist(1, 1 + _wrapNonceLen));
          wrapTagCT = Uint8List.fromList(wrapWire.sublist(1 + _wrapNonceLen));

          if (dekThumb != null) {
            final thumbWrapWire = await Aead.encrypt(
              version: kVerAesGcm,
              key: mk,
              plaintext: dekThumb,
              aad: wrapAad,
            );
            thumbWrapNonce =
                Uint8List.fromList(thumbWrapWire.sublist(1, 1 + _wrapNonceLen));
            thumbWrapTagCT =
                Uint8List.fromList(thumbWrapWire.sublist(1 + _wrapNonceLen));
          }
        });
      } finally {
        dekThumb?.fillRange(0, dekThumb.length, 0);
      }

      return UploadEnvelope(
        mediaId: mediaId,
        cipherBytes: cipher,
        wrapNonce: wrapNonce,
        wrapTagCT: wrapTagCT,
        epoch: currentEpoch,
        blobSize: cipher.length,
        blobSha256: blobSha256,
        mediaType: mediaType,
        // photos are always re encoded to JPEG, so the stored mime must say so
        // regardless of the picker's input mime (a decoded PNG becomes JPEG)
        mimeType: mediaType == 'photo' ? 'image/jpeg' : mimeType,
        filePlaintext: bytesToEncrypt,
        thumbCipherBytes: thumbCipher,
        thumbWrapNonce: thumbWrapNonce,
        thumbWrapTagCT: thumbWrapTagCT,
        thumbSha256: thumbSha256,
        thumbPlaintext: thumbPlaintext,
      );
    } finally {
      dek.fillRange(0, dek.length, 0);
    }
  }
}

// _wrapAad builds album_id(16) ‖ uint32_be(epoch) per §5.1 + §4.1 ; the same
// AAD must be passed to Aead.decrypt on the download side or unwrap fails
Uint8List _wrapAad(Uint8List albumIdBytes, int epoch) {
  final out = Uint8List(_mediaIdLen + 4);
  out.setRange(0, _mediaIdLen, albumIdBytes);
  ByteData.sublistView(out, _mediaIdLen).setUint32(0, epoch, Endian.big);
  return out;
}

// thumb AAD = media_id(16) ‖ "thumb"(5). Distinct from the file cipher's
// AAD (= media_id alone) so a tampered server cant swap a thumb object with a
// file object from the same row : the AEAD tag mismatches on decrypt
Uint8List _thumbAad(Uint8List mediaId) {
  final out = Uint8List(mediaId.length + _kThumbAadSuffix.length);
  out.setRange(0, mediaId.length, mediaId);
  out.setRange(mediaId.length, out.length, _kThumbAadSuffix);
  return out;
}

class _StrippedAndThumb {
  final Uint8List cleanJpeg;
  final Uint8List thumb;
  const _StrippedAndThumb(this.cleanJpeg, this.thumb);
}

// _stripExifAndThumb : decode the picked photo (img.decodeImage auto applies
// EXIF orientation, so pixels come back upright), CLEAR the remaining EXIF, then
// re encode as a clean JPEG + pull a 400px long-edge thumbnail off the same
// Image. Returns null if the bytes arent a decodable image : the caller fails
// closed rather than upload unstripped bytes
_StrippedAndThumb? _stripExifAndThumb(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  // Drop EXIF (GPS, camera, capture time) + any XMP/IPTC BEFORE re encoding :
  // package:image parses EXIF into decoded.exif and encodeJpg writes it back
  // out, so decoding alone does NOT strip it. Clearing here means both the
  // clean JPEG and the thumbnail (derived below from the same Image) are
  // metadata free. ICC colour profile is left alone (not privacy sensitive)
  decoded.exif = img.ExifData();
  final cleanJpeg = img.encodeJpg(decoded, quality: 90);
  // Resize the LONG edge to _thumbMaxDim. copyResize preserves aspect ratio
  // when only one of width/height is given
  final thumbImg = decoded.width >= decoded.height
      ? img.copyResize(decoded, width: _thumbMaxDim)
      : img.copyResize(decoded, height: _thumbMaxDim);
  final thumb = img.encodeJpg(thumbImg, quality: _thumbJpegQuality);
  return _StrippedAndThumb(cleanJpeg, thumb);
}

Future<Uint8List> _sha256(Uint8List bytes) async {
  final h = await cg.Sha256().hash(bytes);
  return Uint8List.fromList(h.bytes);
}

// _newUuidBytes : v4 UUID as raw 16 bytes. Server expects the same bytes
// for AAD on decrypt : the wire form (8-4-4-4-12 string) is just for JSON
Uint8List _newUuidBytes() {
  final s = const Uuid().v4();
  final hex = s.replaceAll('-', '');
  if (hex.length != 32) {
    throw StateError('uuid v4 returned non 32 hex char: $s');
  }
  final out = Uint8List(_mediaIdLen);
  for (var i = 0; i < _mediaIdLen; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _uuidStringFromBytes(Uint8List b) {
  final s = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
      '-${s.substring(16, 20)}-${s.substring(20)}';
}
