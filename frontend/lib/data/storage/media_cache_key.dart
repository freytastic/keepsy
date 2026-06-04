// Composite key for the media cache layers. asset distinguishes full file
// from thumbnail so a single album_id+media_id+epoch can carry both blobs
// without colliding. epoch_tag is part of the key so a hypothetical row
// re encrypted under a new epoch never reads back an old plaintext

enum CacheAsset { file, thumb }

class MediaCacheKey {
  final String albumId;
  final String mediaId;
  final int epochTag;
  final CacheAsset asset;

  const MediaCacheKey({
    required this.albumId,
    required this.mediaId,
    required this.epochTag,
    required this.asset,
  });

  // diskFilename omits epoch_tag : disk blobs are 1:1 with media_id (epoch
  // pins which MK unwraps the DEK, lives on the row in records.db instead)
  String get diskFilename =>
      asset == CacheAsset.thumb ? '$mediaId.thumb.bin' : '$mediaId.bin';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MediaCacheKey &&
          albumId == other.albumId &&
          mediaId == other.mediaId &&
          epochTag == other.epochTag &&
          asset == other.asset;

  @override
  int get hashCode => Object.hash(albumId, mediaId, epochTag, asset);
}
