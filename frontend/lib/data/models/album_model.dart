class AlbumModel {
  final String id;
  // Raw base64 name_ct as stored server side (sealed under the album MK, or a
  // legacy placeholder). Decrypted for display via resolveAlbumName : the UI
  // reads the resolved string from AppState.albumDisplayName, never this field
  final String? nameCt;
  final DateTime createdAt;
  final DateTime updatedAt;
  // memberToken : the caller's own member_token for this album, base64. Set
  // on /albums/{id} GET (servers fills it from RequireMember context) and on
  // POST /albums (the creator's freshly minted token). Null on ListAlbums
  // entries where the server hasnt resolved per album member context yet
  final String? memberToken;

  AlbumModel({
    required this.id,
    required this.nameCt,
    required this.createdAt,
    required this.updatedAt,
    this.memberToken,
  });

  AlbumModel copyWith({String? nameCt}) => AlbumModel(
        id: id,
        nameCt: nameCt ?? this.nameCt,
        createdAt: createdAt,
        updatedAt: updatedAt,
        memberToken: memberToken,
      );

  factory AlbumModel.fromJson(Map<String, dynamic> json) {
    return AlbumModel(
      id: json['id'] ?? '',
      nameCt: json['name_ct'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'])
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'])
          : DateTime.now(),
      memberToken: json['member_token'] as String?,
    );
  }
}
