import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/models/member_model.dart';

final _wire = {
  'avatar_id': '6f1c7c2e-0000-4000-8000-000000000001',
  'blob_size': 131101,
  'blob_sha256': base64.encode(Uint8List.fromList(List.filled(32, 7))),
  'key_ct': base64.encode(Uint8List.fromList(List.filled(65, 8))),
};

void main() {
  test('a listing avatar survives the offline shelf round trip', () {
    final album = AlbumModel.fromJson({
      'id': 'a1',
      'media_generation': 3,
      'member_previews': [
        {'member_token': 'tok', 'name_ct': null, 'avatar': _wire},
        {'member_token': 'bare', 'name_ct': null},
      ],
    });
    final back = AlbumModel.fromJson(
        jsonDecode(jsonEncode(album.toJson())) as Map<String, dynamic>);

    final ref = back.memberPreviews.first.avatar!;
    expect(ref.avatarId, _wire['avatar_id']);
    expect(ref.blobSize, 131101);
    expect(ref.blobSha256, List.filled(32, 7));
    expect(ref.keyCt, List.filled(65, 8));
    expect(back.memberPreviews.last.avatar, isNull);
  });

  test('the roster carries the avatar in the member profile', () {
    final m = AlbumMember.fromJson({
      'member_token': 'tok',
      'role': 'member',
      'joined_at': '2026-09-23T10:00:00Z',
      'profile': {'ik_pub': null, 'avatar': _wire},
    });
    expect(m.profile.avatar?.avatarId, _wire['avatar_id']);
  });

  test('a malformed avatar is dropped, not the member', () {
    final album = AlbumModel.fromJson({
      'id': 'a1',
      'member_previews': [
        {
          'member_token': 'tok',
          'avatar': {'avatar_id': 'x', 'blob_size': 'big'}
        },
      ],
    });
    expect(album.memberPreviews.single.memberToken, 'tok');
    expect(album.memberPreviews.single.avatar, isNull);
  });
}
