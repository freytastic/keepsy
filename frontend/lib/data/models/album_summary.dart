import 'dart:convert';
import 'dart:typed_data';

class PreviewMedia {
  final String mediaId;
  final int epochTag;
  final Uint8List thumbWrapNonce;
  final Uint8List thumbWrapTagCT;
  final int thumbSize;
  final Uint8List thumbSha256;

  const PreviewMedia({
    required this.mediaId,
    required this.epochTag,
    required this.thumbWrapNonce,
    required this.thumbWrapTagCT,
    required this.thumbSize,
    required this.thumbSha256,
  });

  Map<String, dynamic> toJson() => {
        'media_id': mediaId,
        'epoch_tag': epochTag,
        'thumb_wrap_nonce': base64.encode(thumbWrapNonce),
        'thumb_wrap_tag_ct': base64.encode(thumbWrapTagCT),
        'thumb_size': thumbSize,
        'thumb_sha256': base64.encode(thumbSha256),
      };

  static PreviewMedia? tryFromRecordJson(Map<String, dynamic> json) {
    try {
      if (json['thumb_size'] == null) return null;
      Uint8List b(String k) =>
          base64.decode(base64.normalize(json[k] as String));
      return PreviewMedia(
        mediaId: json['id'] as String,
        epochTag: (json['epoch_tag'] as num).toInt(),
        thumbWrapNonce: b('thumb_wrap_nonce'),
        thumbWrapTagCT: b('thumb_wrap_tag_ct'),
        thumbSize: (json['thumb_size'] as num).toInt(),
        thumbSha256: b('thumb_sha256'),
      );
    } catch (_) {
      return null;
    }
  }

  static PreviewMedia? tryFromJson(Map<String, dynamic> json) {
    try {
      Uint8List b(String k) =>
          base64.decode(base64.normalize(json[k] as String));
      return PreviewMedia(
        mediaId: json['media_id'] as String,
        epochTag: json['epoch_tag'] as int,
        thumbWrapNonce: b('thumb_wrap_nonce'),
        thumbWrapTagCT: b('thumb_wrap_tag_ct'),
        thumbSize: json['thumb_size'] as int,
        thumbSha256: b('thumb_sha256'),
      );
    } catch (_) {
      return null;
    }
  }
}

class MemberPreview {
  final String memberToken;
  final String? nameCt;

  const MemberPreview({required this.memberToken, this.nameCt});

  Map<String, dynamic> toJson() => {
        'member_token': memberToken,
        if (nameCt != null) 'name_ct': nameCt,
      };

  static MemberPreview? tryFromJson(Map<String, dynamic> json) {
    final token = json['member_token'];
    if (token is! String || token.isEmpty) return null;
    return MemberPreview(
        memberToken: token, nameCt: json['name_ct'] as String?);
  }
}
