class AlbumModel {
  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  // memberToken : the caller's own member_token for this album, base64. Set
  // on /albums/{id} GET (servers fills it from RequireMember context) and on
  // POST /albums (the creator's freshly minted token). Null on ListAlbums
  // entries where the server hasnt resolved per album member context yet
  final String? memberToken;

  AlbumModel({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.memberToken,
  });

  factory AlbumModel.fromJson(Map<String, dynamic> json) {
    return AlbumModel(
      id: json['id'] ?? '',
      // Server sends 'name_ct' base64. Phase 5 wires actual MK based decrypt :
      // until then the client renders the base64 ciphertext as a placeholder
      name: json['name_ct'] ?? 'Untitled Album',
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
