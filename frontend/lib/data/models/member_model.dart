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

  // First character for member chips. M7 placeholder : until the client wires
  // up name_ct decryption (Phase 5) we fall back to the first char of the
  // pseudonymous token. Returns '?' for the degenerate empty token case
  String get displayInitial {
    return memberToken.isNotEmpty ? memberToken[0].toUpperCase() : '?';
  }

  // Short pseudonymous label used while name_ct decryption isn't wired yet
  // First 8 chars of the (base64) token : enough to disambiguate : full
  // token is too long for a chip
  String get displayName {
    return memberToken.length > 8 ? memberToken.substring(0, 8) : memberToken;
  }
}
