class MemberProfile {
  final String? ikPub;
  // §4.2 D1 : lk_pub is required by the X3DH responder. Tolerated as null in
  // the decoder for transition compat, but fetches against a current server
  // will populate it
  final String? lkPub;
  final String? name;
  final String? avatarKey;

  MemberProfile({this.ikPub, this.lkPub, this.name, this.avatarKey});

  factory MemberProfile.fromJson(Map<String, dynamic> json) => MemberProfile(
        ikPub: json['ik_pub'] as String?,
        lkPub: json['lk_pub'] as String?,
        name: json['name'] as String?,
        avatarKey: json['avatar_key'] as String?,
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

  String get displayInitial {
    final n = profile.name;
    if (n != null && n.isNotEmpty) return n[0].toUpperCase();
    return memberToken.isNotEmpty ? memberToken[0].toUpperCase() : '?';
  }
}
