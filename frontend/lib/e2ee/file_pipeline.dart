import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
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
  });

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
      // Algorithm select by plaintext size only (D5) : <1 MiB → VER=0x01
      // single tag, >=1 MiB → VER=0x03 streaming. Anything that picks an
      // algorithm from anywhere other than this size check is a bug
      Uint8List cipher;
      if (plaintext.length < kSegmentSize) {
        cipher = await Aead.encrypt(
          version: kVerAesGcm,
          key: dek,
          plaintext: plaintext,
          aad: mediaId,
        );
      } else {
        cipher = await AeadStream.encryptBytes(
          dek: dek,
          plaintext: plaintext,
          mediaId: mediaId,
        );
      }

      final blobSha256 = await _sha256(cipher);

      final wrapAad = _wrapAad(albumIdBytes, currentEpoch);
      final wrapWire = await Aead.encrypt(
        version: kVerAesGcm,
        key: await _useMkBytes(aks, albumIdBytes, currentEpoch),
        plaintext: dek,
        aad: wrapAad,
      );
      if (wrapWire.length != _wrapWireLen) {
        throw StateError(
            'wrap wire length = ${wrapWire.length}, want $_wrapWireLen');
      }
      final wrapNonce =
          Uint8List.fromList(wrapWire.sublist(1, 1 + _wrapNonceLen));
      final wrapTagCT = Uint8List.fromList(wrapWire.sublist(1 + _wrapNonceLen));

      return UploadEnvelope(
        mediaId: mediaId,
        cipherBytes: cipher,
        wrapNonce: wrapNonce,
        wrapTagCT: wrapTagCT,
        epoch: currentEpoch,
        blobSize: cipher.length,
        blobSha256: blobSha256,
        mediaType: mediaType,
        mimeType: mimeType,
      );
    } finally {
      dek.fillRange(0, dek.length, 0);
    }
  }

  // _useMkBytes : helper that pulls the MK bytes out via AlbumKeyStore.useMk
  // and returns a copy. Caller is responsible for zeroing : in prepareUpload
  // we hand the bytes straight to Aead.encrypt which doesnt retain them
  // beyond the call. Aead.encrypt copies into the underlying SecretKey
  static Future<Uint8List> _useMkBytes(
      AlbumKeyStore aks, Uint8List albumIdBytes, int epoch) async {
    return aks.useMk<Uint8List>(albumIdBytes, epoch, (mk) async {
      return Uint8List.fromList(mk);
    });
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
