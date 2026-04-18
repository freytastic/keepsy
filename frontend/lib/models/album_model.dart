class Collaborator {
  final String id;
  final String name;
  final List<String> gradientColors;
  final String initials;

  Collaborator({
    required this.id,
    required this.name,
    required this.gradientColors,
    required this.initials,
  });

  factory Collaborator.fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String? ?? 'User';
    final initials = name.trim().isNotEmpty
        ? name.trim().split(' ').map((e) => e[0]).take(2).join().toUpperCase()
        : '?';

    List<String> colors = ['#000000', '#333333'];
    if (json['gradientColors'] != null) {
      colors = List<String>.from(json['gradientColors']);
    } else if (json['accent_color'] != null) {
       colors = [json['accent_color'], json['accent_color']];
    }

    return Collaborator(
      id: json['id'] ?? '',
      name: name,
      gradientColors: colors,
      initials: initials,
    );
  }
}

class AlbumModel {
  final String id;
  final String name;
  final String emoji;
  final List<String> gradientColors;
  final String? coverPhotoUrl;
  final int totalPhotos;
  final List<Collaborator> collaborators;

  AlbumModel({
    required this.id,
    required this.name,
    required this.emoji,
    required this.gradientColors,
    this.coverPhotoUrl,
    required this.totalPhotos,
    required this.collaborators,
  });

  factory AlbumModel.fromJson(Map<String, dynamic> json) {
    return AlbumModel(
      id: json['id'] ?? '',
      name: json['name'] ?? 'Untitled Album',
      emoji: json['emoji'] ?? '📁',
      gradientColors: json['gradientColors'] != null 
          ? List<String>.from(json['gradientColors']) 
          : ['#2F3336', '#1E2022'], // Default dark gradient fallback
      coverPhotoUrl: json['coverUrl'] ?? json['coverPhotoUrl'],
      totalPhotos: json['mediaCount'] ?? json['totalPhotos'] ?? 0,
      collaborators: json['collaborators'] != null
          ? (json['collaborators'] as List).map((c) => Collaborator.fromJson(c)).toList()
          : [],
    );
  }
}
