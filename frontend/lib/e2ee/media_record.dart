import 'dart:convert';
import 'dart:typed_data';

// MediaRecord mirrors one row from GET /albums/{id}/media. The wire shape is
// what the §5.1 ListMedia handler emits : the bytes a §5.2 download needs to
// unwrap the DEK and decrypt are exactly wrapNonce + wrapTagCT + epochTag +
// the album's MK pulled from AlbumKeyStore. blobSha256 is verified after
// download to catch in flight tamper before the AEAD layer even runs

class MediaRecord {
  final String id; // canonical UUID string
  final String albumId;
  final String uploaderToken; // base64 raw 32B
  final Uint8List wrapNonce; // 12 bytes
  final Uint8List wrapTagCT; // 48 bytes (16 tag + 32 ct of DEK)
  final int epochTag;
  final int blobSize; // exact ciphertext byte count uploaded
  final Uint8List blobSha256; // 32 bytes
  final String mediaType; // 'photo' | 'video'
  final String? mimeType;
  final DateTime createdAt;

  const MediaRecord({
    required this.id,
    required this.albumId,
    required this.uploaderToken,
    required this.wrapNonce,
    required this.wrapTagCT,
    required this.epochTag,
    required this.blobSize,
    required this.blobSha256,
    required this.mediaType,
    required this.mimeType,
    required this.createdAt,
  });

  factory MediaRecord.fromJson(Map<String, dynamic> json) {
    return MediaRecord(
      id: json['id'] as String,
      albumId: json['album_id'] as String,
      uploaderToken: json['uploader_token'] as String,
      wrapNonce: base64Decode(json['wrap_nonce'] as String),
      wrapTagCT: base64Decode(json['wrap_tag_ct'] as String),
      epochTag: (json['epoch_tag'] as num).toInt(),
      blobSize: (json['blob_size'] as num).toInt(),
      blobSha256: base64Decode(json['blob_sha256'] as String),
      mediaType: json['media_type'] as String,
      mimeType: json['mime_type'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  // Raw 16 byte form of the media id. AAD construction in the §5.1/§5.2
  // decrypt path uses these bytes, not the canonical string
  Uint8List get mediaIdBytes {
    final hex = id.replaceAll('-', '');
    if (hex.length != 32) {
      throw FormatException('media id is not a canonical UUID: $id');
    }
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  // Raw 16 byte form of the album id. Same as mediaIdBytes : AAD construction
  // for the wrap (album_id ‖ u32_be(epoch)) needs these bytes
  Uint8List get albumIdBytes {
    final hex = albumId.replaceAll('-', '');
    if (hex.length != 32) {
      throw FormatException('album id is not a canonical UUID: $albumId');
    }
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
