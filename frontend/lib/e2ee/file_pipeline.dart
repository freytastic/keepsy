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
import 'jpeg_budget.dart';
import 'jpeg_sanity.dart';

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

// One native decode produces metadata-free full and thumbnail JPEGs
class TranscodedPhoto {
  final Uint8List jpeg;
  final Uint8List thumb;
  final int width;
  final int height;
  const TranscodedPhoto({
    required this.jpeg,
    required this.thumb,
    required this.width,
    required this.height,
  });
}

// A photo re encoded without metadata, ready to encrypt
class CleanPhoto {
  final Uint8List jpeg;
  final Uint8List thumb;
  const CleanPhoto({required this.jpeg, required this.thumb});
}

// Rejection must not fall back to the uncapped Dart decoder
sealed class TranscodeOutcome {
  const TranscodeOutcome();
}

class TranscodeDone extends TranscodeOutcome {
  final TranscodedPhoto photo;
  const TranscodeDone(this.photo);
}

// The bridge could not identify the format, so Dart may try
class TranscodeUnavailable extends TranscodeOutcome {
  const TranscodeUnavailable();
}

// The bridge read the header but could not decode safely
class TranscodeRejected extends TranscodeOutcome {
  final String reason;
  const TranscodeRejected(this.reason);
}

// Injected because the Dart fallback isolate has no binary messenger
typedef ImageTranscoder = Future<TranscodeOutcome> Function(Uint8List bytes);

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
  // Plaintext kept only in memory to seed the post upload cache
  final Uint8List? filePlaintext;
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
    this.filePlaintext,
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

// Media encrypted under fresh DEKs but not yet bound to an album key
class EncryptedMedia {
  final Uint8List mediaId;
  final Uint8List cipherBytes;
  final Uint8List blobSha256;
  final Uint8List dek;
  final String mediaType;
  final String? mimeType;
  final Uint8List? thumbCipherBytes;
  final Uint8List? thumbSha256;
  final Uint8List? thumbDek;
  final Uint8List? filePlaintext;
  final Uint8List? thumbPlaintext;

  const EncryptedMedia({
    required this.mediaId,
    required this.cipherBytes,
    required this.blobSha256,
    required this.dek,
    required this.mediaType,
    required this.mimeType,
    this.thumbCipherBytes,
    this.thumbSha256,
    this.thumbDek,
    this.filePlaintext,
    this.thumbPlaintext,
  });

  int get payloadByteLength =>
      cipherBytes.length + (thumbCipherBytes?.length ?? 0);

  void zeroKeys() {
    dek.fillRange(0, dek.length, 0);
    final t = thumbDek;
    if (t != null) t.fillRange(0, t.length, 0);
  }

  void zeroAll() {
    zeroKeys();
    for (final b in [filePlaintext, thumbPlaintext]) {
      if (b != null) b.fillRange(0, b.length, 0);
    }
  }
}

abstract class FilePipeline {
  // Encrypts with fresh DEKs, wraps them under the current MK, then zeroes them
  static Future<UploadEnvelope> prepareUpload({
    required AlbumKeyStore aks,
    required Uint8List albumIdBytes,
    required int currentEpoch,
    required Uint8List plaintext,
    required String mediaType,
    String? mimeType,
    // Stable across retries because media ID is AEAD AAD
    Uint8List? mediaId,
    ImageTranscoder? transcode,
  }) async {
    if (albumIdBytes.length != _mediaIdLen) {
      throw ArgumentError(
          'albumIdBytes must be 16 bytes, got ${albumIdBytes.length}');
    }
    final span = Trace.start('media.prepareUpload', fields: {
      'kind': mediaType,
      'input_bytes': plaintext.length,
      'epoch': currentEpoch,
    });
    try {
      final media = await encryptMedia(
        plaintext: plaintext,
        mediaType: mediaType,
        mimeType: mimeType,
        mediaId: mediaId,
        transcode: transcode,
      );
      try {
        final env = await wrapKeys(
          aks: aks,
          albumIdBytes: albumIdBytes,
          epoch: currentEpoch,
          media: media,
        );
        span.end(fields: {
          'file_bytes': env.blobSize,
          'thumb_bytes': env.thumbSize,
        });
        return env;
      } finally {
        media.zeroKeys();
      }
    } catch (e) {
      span.fail(Trace.reasonOf(e));
      rethrow;
    }
  }

  // Metadata free full JPEG and thumbnail from one decode. Throws
  // UnprocessableImageException rather than ever returning the original bytes
  static Future<CleanPhoto> cleanPhoto(
    Uint8List plaintext, {
    ImageTranscoder? transcode,
    Map<String, Object?> traceFields = const {},
  }) async {
    // Prefer the faster bounded platform codec for phone photos
    final outcome = transcode == null
        ? const TranscodeUnavailable()
        : await Trace.measure<TranscodeOutcome>(
            'media.imageTranscode',
            () => transcode(plaintext),
            fields: {...traceFields, 'bytes': plaintext.length},
            endFields: (result) => switch (result) {
              TranscodeDone(:final photo) => {
                  'transcoded': true,
                  'file_bytes': photo.jpeg.length,
                  'thumb_bytes': photo.thumb.length,
                  'width': photo.width,
                  'height': photo.height,
                },
              TranscodeRejected(:final reason) => {
                  'transcoded': false,
                  'refused': reason,
                },
              TranscodeUnavailable() => {
                  'transcoded': false,
                  'refused': 'unavailable',
                },
            },
          );

    switch (outcome) {
      case TranscodeDone(:final photo):
        final file = Trace.measureSync<SanitizedJpeg?>(
          'media.jpegSanitize',
          () => JpegSanity.sanitize(photo.jpeg),
          fields: {...traceFields, 'bytes': photo.jpeg.length},
        );
        final thumb = Trace.measureSync<SanitizedJpeg?>(
          'media.jpegSanitizeThumb',
          () => JpegSanity.sanitize(photo.thumb),
          fields: {...traceFields, 'bytes': photo.thumb.length},
        );
        if (file == null || thumb == null) {
          // Log only the marker where validation stopped
          Trace.event('media.imageSanitizeRefused', fields: {
            ...traceFields,
            'file': file == null ? JpegSanity.describe(photo.jpeg) : 'ok',
            'thumb': thumb == null ? JpegSanity.describe(photo.thumb) : 'ok',
          });
          throw const UnprocessableImageException(
              'transcoded photo is not a whole JPEG');
        }
        // Record metadata markers removed from platform output
        Trace.event('media.imageSanitize', fields: {
          ...traceFields,
          'stripped': _markerList(file.stripped),
          'thumb_stripped': _markerList(thumb.stripped),
        });
        return CleanPhoto(jpeg: file.bytes, thumb: thumb.bytes);
      case TranscodeRejected(:final reason):
        throw UnprocessableImageException('platform refused it: $reason');
      case TranscodeUnavailable():
        final stripped = await Trace.measure<_StrippedAndThumb?>(
          'media.imageWork',
          () => _stripExifAndThumb(plaintext),
          fields: {...traceFields, 'bytes': plaintext.length},
          endFields: (result) => {'decoded': result != null},
        );
        if (stripped == null) {
          throw const UnprocessableImageException(
              'photo could not be decoded to strip metadata');
        }
        _emitImageSpans(stripped, plaintext.length, traceFields);
        return CleanPhoto(jpeg: stripped.cleanJpeg, thumb: stripped.thumb);
    }
  }

  // Needs no album key because the file AAD is only the media id
  static Future<EncryptedMedia> encryptMedia({
    required Uint8List plaintext,
    required String mediaType,
    String? mimeType,
    Uint8List? mediaId,
    ImageTranscoder? transcode,
  }) async {
    if (mediaType != 'photo' && mediaType != 'video') {
      throw ArgumentError(
          "mediaType must be 'photo' or 'video', got $mediaType");
    }
    if (mediaId != null && mediaId.length != _mediaIdLen) {
      throw ArgumentError('mediaId must be 16 bytes, got ${mediaId.length}');
    }
    final id = mediaId ?? _newUuidBytes();
    final traceFields = <String, Object?>{
      'media': Trace.id(_uuidStringFromBytes(id)),
      'kind': mediaType,
      'input_bytes': plaintext.length,
    };
    final dek = Csprng.bytes(_dekLen);
    Uint8List? dekThumb;
    try {
      // Photos are re-encoded without metadata and reuse one thumbnail decode
      // Undecodable photos fail closed while videos keep their original bytes
      Uint8List bytesToEncrypt = plaintext;
      Uint8List? thumbPlaintext;
      if (mediaType == 'photo') {
        final clean = await cleanPhoto(plaintext,
            transcode: transcode, traceFields: traceFields);
        bytesToEncrypt = clean.jpeg;
        thumbPlaintext = clean.thumb;
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

      // A separate thumbnail DEK limits a single DEK compromise
      // Distinct AAD prevents swapping file and thumbnail objects
      Uint8List? thumbCipher;
      Uint8List? thumbSha256;
      if (thumbPlaintext != null) {
        dekThumb = Csprng.bytes(_dekLen);
        final ct = await Aead.encrypt(
          version: kVerAesGcm,
          key: dekThumb,
          plaintext: thumbPlaintext,
          aad: _thumbAad(id),
        );
        thumbCipher = ct;
        thumbSha256 = await Trace.measure<Uint8List>(
          'media.hashThumb',
          () => _sha256(ct),
          fields: {...traceFields, 'bytes': ct.length},
        );
      }

      return EncryptedMedia(
        mediaId: id,
        cipherBytes: cipher,
        blobSha256: await Trace.measure<Uint8List>(
          'media.hashFile',
          () => _sha256(cipher),
          fields: {...traceFields, 'bytes': cipher.length},
        ),
        dek: dek,
        mediaType: mediaType,
        // Photos are re-encoded as JPEG regardless of their input format
        mimeType: mediaType == 'photo' ? 'image/jpeg' : mimeType,
        thumbCipherBytes: thumbCipher,
        thumbSha256: thumbSha256,
        thumbDek: dekThumb,
        filePlaintext: bytesToEncrypt,
        thumbPlaintext: thumbPlaintext,
      );
    } catch (_) {
      dek.fillRange(0, dek.length, 0);
      dekThumb?.fillRange(0, dekThumb.length, 0);
      rethrow;
    }
  }

  // Keeps MK bytes inside one useMk callback while wrapping both DEKs
  static Future<UploadEnvelope> wrapKeys({
    required AlbumKeyStore aks,
    required Uint8List albumIdBytes,
    required int epoch,
    required EncryptedMedia media,
  }) async {
    if (albumIdBytes.length != _mediaIdLen) {
      throw ArgumentError(
          'albumIdBytes must be 16 bytes, got ${albumIdBytes.length}');
    }
    final wrapAad = _wrapAad(albumIdBytes, epoch);
    final thumbDek = media.thumbCipherBytes == null ? null : media.thumbDek;
    late final Uint8List wrapNonce;
    late final Uint8List wrapTagCT;
    Uint8List? thumbWrapNonce;
    Uint8List? thumbWrapTagCT;
    await Trace.measure<void>(
      'media.keyWrap',
      () => aks.useMk<void>(albumIdBytes, epoch, (mk) async {
        final wrapWire = await Aead.encrypt(
          version: kVerAesGcm,
          key: mk,
          plaintext: media.dek,
          aad: wrapAad,
        );
        if (wrapWire.length != _wrapWireLen) {
          throw StateError(
              'wrap wire length = ${wrapWire.length}, want $_wrapWireLen');
        }
        wrapNonce = Uint8List.fromList(wrapWire.sublist(1, 1 + _wrapNonceLen));
        wrapTagCT = Uint8List.fromList(wrapWire.sublist(1 + _wrapNonceLen));

        if (thumbDek != null) {
          final thumbWrapWire = await Aead.encrypt(
            version: kVerAesGcm,
            key: mk,
            plaintext: thumbDek,
            aad: wrapAad,
          );
          thumbWrapNonce =
              Uint8List.fromList(thumbWrapWire.sublist(1, 1 + _wrapNonceLen));
          thumbWrapTagCT =
              Uint8List.fromList(thumbWrapWire.sublist(1 + _wrapNonceLen));
        }
      }),
      fields: {
        'media': Trace.id(_uuidStringFromBytes(media.mediaId)),
        'epoch': epoch,
        'wraps': thumbDek == null ? 1 : 2,
      },
    );

    return UploadEnvelope(
      mediaId: media.mediaId,
      cipherBytes: media.cipherBytes,
      wrapNonce: wrapNonce,
      wrapTagCT: wrapTagCT,
      epoch: epoch,
      blobSize: media.cipherBytes.length,
      blobSha256: media.blobSha256,
      mediaType: media.mediaType,
      mimeType: media.mimeType,
      filePlaintext: media.filePlaintext,
      thumbCipherBytes: thumbDek == null ? null : media.thumbCipherBytes,
      thumbWrapNonce: thumbWrapNonce,
      thumbWrapTagCT: thumbWrapTagCT,
      thumbSha256: thumbDek == null ? null : media.thumbSha256,
      thumbPlaintext: media.thumbPlaintext,
    );
  }

  static Future<Uint8List?> openThumb(EncryptedMedia media) async {
    final cipher = media.thumbCipherBytes;
    final dek = media.thumbDek;
    if (cipher == null || dek == null) return null;
    return openThumbCipher(mediaId: media.mediaId, cipher: cipher, dek: dek);
  }

  static Future<Uint8List> openThumbCipher({
    required Uint8List mediaId,
    required Uint8List cipher,
    required Uint8List dek,
  }) =>
      Aead.decrypt(wire: cipher, key: dek, aad: _thumbAad(mediaId));
}

// Wrap AAD is album_id(16) followed by uint32_be(epoch) and must match on download
Uint8List _wrapAad(Uint8List albumIdBytes, int epoch) {
  final out = Uint8List(_mediaIdLen + 4);
  out.setRange(0, _mediaIdLen, albumIdBytes);
  ByteData.sublistView(out, _mediaIdLen).setUint32(0, epoch, Endian.big);
  return out;
}

// Thumbnail AAD differs from file AAD so the server cannot swap their objects
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

Future<_StrippedAndThumb?> _stripExifAndThumb(Uint8List bytes) =>
    Isolate.run(() => _stripExifAndThumbSync(bytes));

_StrippedAndThumb? _stripExifAndThumbSync(Uint8List bytes) {
  final watch = Stopwatch()..start();
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    // Some decoders throw on malformed input instead of returning null
    decoded = null;
  }
  final decodeMs = watch.elapsedMilliseconds;
  if (decoded == null) return null;

  // Clear EXIF before encoding because package:image otherwise writes it back
  // Re-encoding also drops XMP and IPTC from the full image and thumbnail
  decoded.exif = img.ExifData();

  watch.reset();
  // Use 4:2:0 for smaller full size images
  final cleanJpeg =
      img.encodeJpg(decoded, quality: 90, chroma: img.JpegChroma.yuv420);
  final encodeMs = watch.elapsedMilliseconds;

  watch.reset();
  final thumbImg = resizeLongEdge(decoded, _thumbMaxDim);
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

BudgetedJpeg _encodeThumbUnderBudget(img.Image src) => encodeJpegUnderBudget(
      src,
      budget: _thumbByteBudget,
      quality: _thumbJpegQuality,
      minQuality: _thumbMinQuality,
      minDim: _thumbMinDim,
    );

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

String _markerList(List<int> markers) => markers.isEmpty
    ? 'none'
    : markers.map((m) => '0x${m.toRadixString(16)}').join(',');

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
