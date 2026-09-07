import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:image/image.dart' as img;
import 'package:keepsy/crypto/aead_stream.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/diagnostics/trace.dart';
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

// Sized for a three column grid while staying below the server limit
const int _thumbMaxDim = 640;
const int _thumbJpegQuality = 82;
// Leaves headroom below the 500 KB thumbnail limit
const int _thumbByteBudget = 420 * 1024;
const int _thumbMinQuality = 60;
const int _thumbMinDim = 320;
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
    // Stable across retries because media ID is AEAD AAD
    Uint8List? mediaId,
  }) async {
    if (albumIdBytes.length != _mediaIdLen) {
      throw ArgumentError(
          'albumIdBytes must be 16 bytes, got ${albumIdBytes.length}');
    }
    if (mediaType != 'photo' && mediaType != 'video') {
      throw ArgumentError(
          "mediaType must be 'photo' or 'video', got $mediaType");
    }

    if (mediaId != null && mediaId.length != _mediaIdLen) {
      throw ArgumentError('mediaId must be 16 bytes, got ${mediaId.length}');
    }
    final id = mediaId ?? _newUuidBytes();
    final dek = Csprng.bytes(_dekLen);
    final traceFields = <String, Object?>{
      'media': Trace.id(_uuidStringFromBytes(id)),
      'kind': mediaType,
      'input_bytes': plaintext.length,
      'epoch': currentEpoch,
    };
    final prepareSpan = Trace.start('media.prepareUpload', fields: traceFields);

    try {
      // Photos are re-encoded without metadata and reuse one thumbnail decode
      // Undecodable photos fail closed while videos keep their original bytes
      Uint8List bytesToEncrypt = plaintext;
      Uint8List? thumbPlaintext;
      if (mediaType == 'photo') {
        final stripped = await Trace.measure<_StrippedAndThumb?>(
          'media.imageWork',
          () => _stripExifAndThumb(plaintext),
          fields: {...traceFields, 'bytes': plaintext.length},
          endFields: (result) => {'decoded': result != null},
        );
        if (stripped != null) {
          _emitImageSpans(stripped, plaintext.length, traceFields);
        }
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
      final cipher = await Trace.measure<Uint8List>(
        'media.fileEncrypt',
        () => bytesToEncrypt.length < kSegmentSize
            ? Aead.encrypt(
                version: kVerAesGcm,
                key: dek,
                plaintext: bytesToEncrypt,
                aad: id,
              )
            : AeadStream.encryptBytes(
                dek: dek,
                plaintext: bytesToEncrypt,
                mediaId: id,
              ),
        fields: {
          ...traceFields,
          'bytes': bytesToEncrypt.length,
          'mode': bytesToEncrypt.length < kSegmentSize ? 'single' : 'stream',
        },
        endFields: (result) => {'output_bytes': result.length},
      );

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
            aad: _thumbAad(id),
          );
          thumbSha256 = await _sha256(thumbCipher);
        }
        await Trace.measure<void>(
          'media.keyWrap',
          () => aks.useMk<void>(albumIdBytes, currentEpoch, (mk) async {
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
              thumbWrapNonce = Uint8List.fromList(
                  thumbWrapWire.sublist(1, 1 + _wrapNonceLen));
              thumbWrapTagCT =
                  Uint8List.fromList(thumbWrapWire.sublist(1 + _wrapNonceLen));
            }
          }),
          fields: {
            ...traceFields,
            'wraps': dekThumb == null ? 1 : 2,
          },
        );
      } finally {
        dekThumb?.fillRange(0, dekThumb.length, 0);
      }

      final envelope = UploadEnvelope(
        mediaId: id,
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
      prepareSpan.end(fields: {
        'file_bytes': envelope.blobSize,
        'thumb_bytes': envelope.thumbSize,
      });
      return envelope;
    } catch (e) {
      prepareSpan.fail(Trace.reasonOf(e));
      rethrow;
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
  final int decodeMs;
  final int encodeMs;
  final int resizeMs;
  final int thumbEncodeMs;
  final int width;
  final int height;
  final int thumbWidth;
  final int thumbHeight;
  final int thumbQuality;

  const _StrippedAndThumb({
    required this.cleanJpeg,
    required this.thumb,
    required this.decodeMs,
    required this.encodeMs,
    required this.resizeMs,
    required this.thumbEncodeMs,
    required this.width,
    required this.height,
    required this.thumbWidth,
    required this.thumbHeight,
    required this.thumbQuality,
  });
}

// Runs image codecs off the Flutter UI isolate
Future<_StrippedAndThumb?> _stripExifAndThumb(Uint8List bytes) =>
    Isolate.run(() => _stripExifAndThumbSync(bytes));

// Returns a cleaned JPEG and thumbnail or null when decoding fails
_StrippedAndThumb? _stripExifAndThumbSync(Uint8List bytes) {
  final watch = Stopwatch()..start();
  final decoded = img.decodeImage(bytes);
  final decodeMs = watch.elapsedMilliseconds;
  if (decoded == null) return null;

  // Drop EXIF (GPS, camera, capture time) + any XMP/IPTC BEFORE re encoding :
  // package:image parses EXIF into decoded.exif and encodeJpg writes it back
  // out, so decoding alone does NOT strip it. Clearing here means both the
  // clean JPEG and the thumbnail (derived below from the same Image) are
  // metadata free. ICC colour profile is left alone (not privacy sensitive)
  decoded.exif = img.ExifData();

  watch.reset();
  // Use 4:2:0 for smaller full size images
  final cleanJpeg =
      img.encodeJpg(decoded, quality: 90, chroma: img.JpegChroma.yuv420);
  final encodeMs = watch.elapsedMilliseconds;

  // Resize the LONG edge to _thumbMaxDim. copyResize preserves aspect ratio
  // when only one of width/height is given
  watch.reset();
  final thumbImg = _resizeLongEdge(decoded, _thumbMaxDim);
  final resizeMs = watch.elapsedMilliseconds;

  // Preserve edge color in small thumbnails
  watch.reset();
  final thumb = _encodeThumbUnderBudget(thumbImg);
  final thumbEncodeMs = watch.elapsedMilliseconds;

  return _StrippedAndThumb(
    cleanJpeg: cleanJpeg,
    thumb: thumb.bytes,
    decodeMs: decodeMs,
    encodeMs: encodeMs,
    resizeMs: resizeMs,
    thumbEncodeMs: thumbEncodeMs,
    width: decoded.width,
    height: decoded.height,
    thumbWidth: thumb.width,
    thumbHeight: thumb.height,
    thumbQuality: thumb.quality,
  );
}

// Average interpolation avoids jagged downscale edges
img.Image _resizeLongEdge(img.Image src, int maxDim) {
  final longEdge = src.width >= src.height ? src.width : src.height;
  if (longEdge <= maxDim) return src;
  return src.width >= src.height
      ? img.copyResize(src,
          width: maxDim, interpolation: img.Interpolation.average)
      : img.copyResize(src,
          height: maxDim, interpolation: img.Interpolation.average);
}

class _Thumb {
  final Uint8List bytes;
  final int width;
  final int height;
  final int quality;
  const _Thumb(this.bytes, this.width, this.height, this.quality);
}

// Lowers quality before dimensions to preserve thumbnail detail
_Thumb _encodeThumbUnderBudget(img.Image src) {
  var image = src;
  var quality = _thumbJpegQuality;
  while (true) {
    final bytes = img.encodeJpg(image, quality: quality);
    if (bytes.length <= _thumbByteBudget) {
      return _Thumb(bytes, image.width, image.height, quality);
    }
    if (quality > _thumbMinQuality) {
      quality -= 8;
      if (quality < _thumbMinQuality) {
        quality = _thumbMinQuality;
      }
      continue;
    }
    final longEdge = image.width >= image.height ? image.width : image.height;
    if (longEdge <= _thumbMinDim) {
      return _Thumb(bytes, image.width, image.height, quality);
    }
    image = _resizeLongEdge(image, (longEdge * 3) ~/ 4);
    quality = _thumbJpegQuality;
  }
}

// Replays isolate timings on the caller trace
void _emitImageSpans(
    _StrippedAndThumb work, int inputBytes, Map<String, Object?> fields) {
  if (!Trace.enabled) return;
  Trace.replay('media.imageDecode', work.decodeMs,
      fields: {...fields, 'bytes': inputBytes},
      endFields: {'decoded': true, 'width': work.width, 'height': work.height});
  Trace.replay('media.imageEncode', work.encodeMs,
      fields: fields,
      endFields: {'bytes': work.cleanJpeg.length, 'quality': 90});
  Trace.replay('media.thumbResize', work.resizeMs,
      fields: fields,
      endFields: {'width': work.thumbWidth, 'height': work.thumbHeight});
  Trace.replay('media.thumbEncode', work.thumbEncodeMs,
      fields: fields,
      endFields: {'bytes': work.thumb.length, 'quality': work.thumbQuality});
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
