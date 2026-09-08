import 'package:keepsy/e2ee/media_record.dart';

class UploaderTally {
  final int photos;
  final int bytes;

  const UploaderTally({required this.photos, required this.bytes});

  UploaderTally _plus(int moreBytes) =>
      UploaderTally(photos: photos + 1, bytes: bytes + moreBytes);
}

// Totals use the stored file and thumbnail sizes
class AlbumStats {
  final int photoCount;
  final int totalBytes;
  final int peopleCount;
  final Map<String, UploaderTally> perUploader;

  const AlbumStats({
    required this.photoCount,
    required this.totalBytes,
    required this.peopleCount,
    required this.perUploader,
  });

  factory AlbumStats.of(
    List<MediaRecord> records, {
    required int peopleCount,
  }) {
    var bytes = 0;
    final byUploader = <String, UploaderTally>{};
    for (final r in records) {
      final size = storedBytes(r);
      bytes += size;
      byUploader[r.uploaderToken] = (byUploader[r.uploaderToken] ??
              const UploaderTally(photos: 0, bytes: 0))
          ._plus(size);
    }
    return AlbumStats(
      photoCount: records.length,
      totalBytes: bytes,
      peopleCount: peopleCount,
      perUploader: Map.unmodifiable(byUploader),
    );
  }

  static int storedBytes(MediaRecord r) => r.blobSize + (r.thumbSize ?? 0);

  List<MapEntry<String, UploaderTally>> get byWeight {
    final entries = perUploader.entries.toList();
    entries.sort((a, b) => b.value.bytes.compareTo(a.value.bytes));
    return List.unmodifiable(entries);
  }

  String summary({int invited = 0}) {
    final people = '$peopleCount ${peopleCount == 1 ? 'person' : 'people'}';
    final tail = invited > 0 ? '$people, $invited invited' : people;
    if (photoCount == 0) return tail;
    final photos = '$photoCount ${photoCount == 1 ? 'photo' : 'photos'}';
    return '$photos · ${formatBytes(totalBytes)} · $tail';
  }

  // byte thresholds
  static String formatBytes(int b) {
    if (b >= 1000000000) return '${(b / 1000000000).toStringAsFixed(1)} GB';
    if (b >= 10000000) return '${(b / 1000000).round()} MB';
    if (b >= 1000000) return '${(b / 1000000).toStringAsFixed(1)} MB';
    return '${(b / 1000).round()} KB';
  }
}
