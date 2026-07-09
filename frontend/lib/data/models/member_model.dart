class MemberProfile {
  final String? ikPub;
  // §4.2 D1 : lk_pub is required by the X3DH responder. Tolerated as null in
  // the decoder for transition compat, but fetches against a current server
  // will populate it
  final String? lkPub;
  // M7 : encrypted display name (locked under the album's MK_current). Server
  // stores opaque bytes : client decrypts using AlbumKeyStore.useMk to render
  // the actual string. Null until the member publishes their first name_ct
  // via PUT /albums/{id}/members/me/profile-ct (full client wiring lands in
  // Phase 5 alongside the encrypted media display path)
  final String? nameCt;

  MemberProfile({this.ikPub, this.lkPub, this.nameCt});

  factory MemberProfile.fromJson(Map<String, dynamic> json) => MemberProfile(
        ikPub: json['ik_pub'] as String?,
        lkPub: json['lk_pub'] as String?,
        nameCt: json['name_ct'] as String?,
      );
}

class AlbumMember {
  final String memberToken;
  final String role;
  final bool revoked;
  final DateTime joinedAt;
  final MemberProfile profile;

  AlbumMember({
    required this.memberToken,
    required this.role,
    required this.revoked,
    required this.joinedAt,
    required this.profile,
  });

  factory AlbumMember.fromJson(Map<String, dynamic> json) => AlbumMember(
        memberToken: json['member_token'] as String,
        role: json['role'] as String,
        revoked: json['revoked'] as bool? ?? false,
        joinedAt: DateTime.parse(json['joined_at'] as String),
        profile: MemberProfile.fromJson(
            json['profile'] as Map<String, dynamic>? ?? {}),
      );
}
