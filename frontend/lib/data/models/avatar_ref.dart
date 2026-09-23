import 'dart:convert';
import 'dart:typed_data';

// A member's current avatar in one album. Holds no storage coordinates, so
// the bytes still need an authorized download URL
class AvatarRef {
  final String avatarId;
  final int blobSize;
  final Uint8List blobSha256;
  final Uint8List keyCt;

  const AvatarRef({
    required this.avatarId,
    required this.blobSize,
    required this.blobSha256,
    required this.keyCt,
  });

  Map<String, dynamic> toJson() => {
        'avatar_id': avatarId,
        'blob_size': blobSize,
        'blob_sha256': base64.encode(blobSha256),
        'key_ct': base64.encode(keyCt),
      };

  static AvatarRef? tryFromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    try {
      return AvatarRef(
        avatarId: json['avatar_id'] as String,
        blobSize: (json['blob_size'] as num).toInt(),
        blobSha256:
            base64.decode(base64.normalize(json['blob_sha256'] as String)),
        keyCt: base64.decode(base64.normalize(json['key_ct'] as String)),
      );
    } catch (_) {
      return null;
    }
  }
}
