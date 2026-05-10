class AlbumModel {
  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  AlbumModel({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
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
    );
  }
}
