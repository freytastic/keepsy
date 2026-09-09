import 'package:keepsy/data/models/album_summary.dart';

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

  final int mediaCount;
  final int activeMemberCount;
  final DateTime? latestActivityAt;
  final int mediaGeneration;
  final List<PreviewMedia> previewMedia;
  final List<MemberPreview> memberPreviews;

  // False when summary values are unknown rather than zero
  final bool hasSummary;

  AlbumModel({
    required this.id,
    required this.nameCt,
    required this.createdAt,
    required this.updatedAt,
    this.memberToken,
    this.mediaCount = 0,
    this.activeMemberCount = 0,
    this.latestActivityAt,
    this.mediaGeneration = 0,
    this.previewMedia = const [],
    this.memberPreviews = const [],
    this.hasSummary = false,
  });

  AlbumModel copyWith({
    String? nameCt,
    int? mediaCount,
    DateTime? latestActivityAt,
    int? mediaGeneration,
    List<PreviewMedia>? previewMedia,
    bool? hasSummary,
  }) =>
      AlbumModel(
        id: id,
        nameCt: nameCt ?? this.nameCt,
        createdAt: createdAt,
        updatedAt: updatedAt,
        memberToken: memberToken,
        mediaCount: mediaCount ?? this.mediaCount,
        activeMemberCount: activeMemberCount,
        latestActivityAt: latestActivityAt ?? this.latestActivityAt,
        mediaGeneration: mediaGeneration ?? this.mediaGeneration,
        previewMedia: previewMedia ?? this.previewMedia,
        memberPreviews: memberPreviews,
        hasSummary: hasSummary ?? this.hasSummary,
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
      hasSummary: json.containsKey('media_generation'),
      mediaCount: json['media_count'] as int? ?? 0,
      activeMemberCount: json['active_member_count'] as int? ?? 0,
      latestActivityAt: json['latest_activity_at'] != null
          ? DateTime.tryParse(json['latest_activity_at'])
          : null,
      mediaGeneration: (json['media_generation'] as num?)?.toInt() ?? 0,
      previewMedia: _list(json['preview_media'], PreviewMedia.tryFromJson),
      memberPreviews: _list(json['member_previews'], MemberPreview.tryFromJson),
    );
  }

  // media_generation preserves hasSummary across disk round trips
  Map<String, dynamic> toJson() => {
        'id': id,
        'name_ct': nameCt,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'member_token': memberToken,
        'media_count': mediaCount,
        'active_member_count': activeMemberCount,
        'latest_activity_at': latestActivityAt?.toIso8601String(),
        if (hasSummary) 'media_generation': mediaGeneration,
        'preview_media': [for (final p in previewMedia) p.toJson()],
        'member_previews': [for (final m in memberPreviews) m.toJson()],
      };

  // Drop malformed summary rows without failing the album list
  static List<T> _list<T>(
      dynamic raw, T? Function(Map<String, dynamic>) parse) {
    if (raw is! List) return const [];
    final out = <T>[];
    for (final e in raw) {
      if (e is! Map<String, dynamic>) continue;
      final v = parse(e);
      if (v != null) out.add(v);
    }
    return out;
  }
}
