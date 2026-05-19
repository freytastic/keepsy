import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:keepsy/crypto/aead_stream.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/e2ee/media_record.dart';

import 'album_keys.dart';

// File decryption pipeline (§5.2). Mirrors file_pipeline.dart in reverse :
// fetch ciphertext → unwrap DEK with MK → verify SHA256 → decrypt fully →
// hand bytes to the caller. Decryption is full file before the caller sees
// any byte (P5 in e2ee.md §2.14) : a tampered byte gives a clean
// FileDecryptError, never a partial image rendered to screen

// (video v2) : currently buffers full ciphertext + plaintext in memory.
// For multi GB videos add a Stream<Uint8List> in / IOSink out variant :
// AeadStream segment math stays identical

// DownloadFn is the byte fetch seam. Real wiring uses a bare http.Client
// (no Bearer header : the presigned URL carries auth) ; tests inject in
// memory bytes
typedef DownloadFn = Future<Uint8List> Function(String url);

class FileDecryptError implements Exception {
  // 'no_mk' | 'wrap_auth_failed' | 'sha256_mismatch' | 'aead_auth_failed'
  // | 'unknown_ver' | 'http_failed' | 'wrong_size'
  final String reason;
  final String? detail;
  const FileDecryptError(this.reason, [this.detail]);
  @override
  String toString() =>
      'FileDecryptError($reason${detail == null ? '' : ': $detail'})';
}

// "thumb" suffix bound into the thumb cipher AAD. Must match
// file_pipeline.dart's _kThumbAadSuffix byte for byte
final Uint8List _kThumbAadSuffix = Uint8List.fromList('thumb'.codeUnits);

abstract class FileDecryptor {
  static const int _wrapNonceLen = 12;
  static const int _wrapTagCTLen = 48;

  // DownloadAndDecrypt runs the full §5.2 sequence. presignedUrl is the
  // result of MediaApi.requestDownloadURL : download is the byte fetch seam
  // (defaults to a real http.Client at the call site). Returns plaintext bytes
  static Future<Uint8List> downloadAndDecrypt({
    required AlbumKeyStore aks,
    required MediaRecord record,
    required String presignedUrl,
    required DownloadFn download,
  }) async {
    if (record.wrapNonce.length != _wrapNonceLen) {
      throw FileDecryptError('wrap_auth_failed',
          'wrap_nonce len ${record.wrapNonce.length}, want $_wrapNonceLen');
    }
    if (record.wrapTagCT.length != _wrapTagCTLen) {
      throw FileDecryptError('wrap_auth_failed',
          'wrap_tag_ct len ${record.wrapTagCT.length}, want $_wrapTagCTLen');
    }

    final albumIdBytes = record.albumIdBytes;
    final mediaIdBytes = record.mediaIdBytes;

    // unwrap DEK using MK_(album, epoch). Reassemble the wrap wire
    // VER ‖ NONCE ‖ TAG_CT and call Aead.decrypt with AAD = album_id ‖ u32_be
    // (epoch). If the server tampered with epoch_tag, AAD diverges and the
    // tag fails before any download starts
    final wrapAad = _wrapAad(albumIdBytes, record.epochTag);
    final wrapWire = Uint8List(1 + _wrapNonceLen + _wrapTagCTLen);
    wrapWire[0] = kVerAesGcm;
    wrapWire.setRange(1, 1 + _wrapNonceLen, record.wrapNonce);
    wrapWire.setRange(1 + _wrapNonceLen, wrapWire.length, record.wrapTagCT);

    Uint8List dek;
    try {
      dek =
          await aks.useMk<Uint8List>(albumIdBytes, record.epochTag, (mk) async {
        return Aead.decrypt(wire: wrapWire, key: mk, aad: wrapAad);
      });
    } on StateError catch (e) {
      // useMk throws StateError when no MK exists for that (album, epoch)
      // Caller may want to trigger catchUpAll and retry
      throw FileDecryptError('no_mk', e.toString());
    } on AeadAuthFailed catch (e) {
      // Either MK is wrong or AAD doesnt match what was used at wrap time
      // (someone tampered with epoch_tag). Either way : refuse
      throw FileDecryptError('wrap_auth_failed', e.toString());
    }

    // download the ciphertext bytes
    final Uint8List cipher;
    try {
      cipher = await download(presignedUrl);
    } catch (e) {
      _zero(dek);
      throw FileDecryptError('http_failed', e.toString());
    }

    try {
      //  SHA256 sanity check before any AEAD work. Catches in flight
      // tamper + S3 drift cheaply : AEAD would catch it too but failing early
      // saves cycles on big videos
      if (cipher.length != record.blobSize) {
        throw FileDecryptError(
            'wrong_size', 'got ${cipher.length}, want ${record.blobSize}');
      }
      final sha = await cg.Sha256().hash(cipher);
      if (!_constTimeEq(Uint8List.fromList(sha.bytes), record.blobSha256)) {
        throw FileDecryptError('sha256_mismatch');
      }

      //decrypt fully BEFORE returning anything to the caller. Per
      // P5 / §5.2 : never stream partial decrypted bytes to a renderer :
      // a half decrypted JPEG already on screen when the tag fails is worse
      // than a clean error honestly
      final ver = cipher[0];
      try {
        if (ver == kVerAesGcm || ver == kVerChaPo) {
          return await Aead.decrypt(wire: cipher, key: dek, aad: mediaIdBytes);
        } else if (ver == kVerStreamGcm) {
          return await AeadStream.decryptBytes(
              dek: dek, wire: cipher, mediaId: mediaIdBytes);
        } else {
          throw FileDecryptError(
              'unknown_ver', '0x${ver.toRadixString(16).padLeft(2, '0')}');
        }
      } on AeadAuthFailed catch (e) {
        throw FileDecryptError('aead_auth_failed', e.toString());
      } on FormatException catch (e) {
        throw FileDecryptError('aead_auth_failed', e.toString());
      }
    } finally {
      _zero(dek);
    }
  }

  //  thumb decrypt : same shape as the file path but uses the row's
  // thumb_wrap_nonce/thumb_wrap_tag_ct + thumb_sha256 + AAD = media_id ‖
  // "thumb". Always VER=0x01 (~20 KB so no streaming math). Caller MUST
  // check record.hasThumb first : throws 'no_thumb' otherwise
  static Future<Uint8List> downloadAndDecryptThumb({
    required AlbumKeyStore aks,
    required MediaRecord record,
    required String presignedUrl,
    required DownloadFn download,
  }) async {
    final thumbNonce = record.thumbWrapNonce;
    final thumbTagCT = record.thumbWrapTagCT;
    final thumbSize = record.thumbSize;
    final thumbSha = record.thumbSha256;
    if (thumbNonce == null ||
        thumbTagCT == null ||
        thumbSize == null ||
        thumbSha == null) {
      throw const FileDecryptError('no_thumb');
    }
    if (thumbNonce.length != _wrapNonceLen) {
      throw FileDecryptError('wrap_auth_failed',
          'thumb_wrap_nonce len ${thumbNonce.length}, want $_wrapNonceLen');
    }
    if (thumbTagCT.length != _wrapTagCTLen) {
      throw FileDecryptError('wrap_auth_failed',
          'thumb_wrap_tag_ct len ${thumbTagCT.length}, want $_wrapTagCTLen');
    }

    final albumIdBytes = record.albumIdBytes;
    final mediaIdBytes = record.mediaIdBytes;
    final wrapAad = _wrapAad(albumIdBytes, record.epochTag);
    final wrapWire = Uint8List(1 + _wrapNonceLen + _wrapTagCTLen);
    wrapWire[0] = kVerAesGcm;
    wrapWire.setRange(1, 1 + _wrapNonceLen, thumbNonce);
    wrapWire.setRange(1 + _wrapNonceLen, wrapWire.length, thumbTagCT);

    Uint8List dek;
    try {
      dek =
          await aks.useMk<Uint8List>(albumIdBytes, record.epochTag, (mk) async {
        return Aead.decrypt(wire: wrapWire, key: mk, aad: wrapAad);
      });
    } on StateError catch (e) {
      throw FileDecryptError('no_mk', e.toString());
    } on AeadAuthFailed catch (e) {
      throw FileDecryptError('wrap_auth_failed', e.toString());
    }

    final Uint8List cipher;
    try {
      cipher = await download(presignedUrl);
    } catch (e) {
      _zero(dek);
      throw FileDecryptError('http_failed', e.toString());
    }

    try {
      if (cipher.length != thumbSize) {
        throw FileDecryptError(
            'wrong_size', 'thumb got ${cipher.length}, want $thumbSize');
      }
      final sha = await cg.Sha256().hash(cipher);
      if (!_constTimeEq(Uint8List.fromList(sha.bytes), thumbSha)) {
        throw FileDecryptError('sha256_mismatch');
      }
      try {
        return await Aead.decrypt(
            wire: cipher, key: dek, aad: _thumbAad(mediaIdBytes));
      } on AeadAuthFailed catch (e) {
        throw FileDecryptError('aead_auth_failed', e.toString());
      } on FormatException catch (e) {
        throw FileDecryptError('aead_auth_failed', e.toString());
      }
    } finally {
      _zero(dek);
    }
  }
}

Uint8List _wrapAad(Uint8List albumIdBytes, int epoch) {
  final out = Uint8List(16 + 4);
  out.setRange(0, 16, albumIdBytes);
  ByteData.sublistView(out, 16).setUint32(0, epoch, Endian.big);
  return out;
}

Uint8List _thumbAad(Uint8List mediaId) {
  final out = Uint8List(mediaId.length + _kThumbAadSuffix.length);
  out.setRange(0, mediaId.length, mediaId);
  out.setRange(mediaId.length, out.length, _kThumbAadSuffix);
  return out;
}

void _zero(Uint8List b) => b.fillRange(0, b.length, 0);

bool _constTimeEq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
