import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/storage/media_cache_key.dart';

void main() {
  test('equality + hashCode by all four fields', () {
    const a = MediaCacheKey(
        albumId: 'A', mediaId: 'M', epochTag: 3, asset: CacheAsset.file);
    const b = MediaCacheKey(
        albumId: 'A', mediaId: 'M', epochTag: 3, asset: CacheAsset.file);
    const c = MediaCacheKey(
        albumId: 'A', mediaId: 'M', epochTag: 3, asset: CacheAsset.thumb);
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    expect(a, isNot(equals(c)));
  });

  test('diskFilename omits epoch', () {
    const k = MediaCacheKey(
        albumId: 'A', mediaId: 'M', epochTag: 7, asset: CacheAsset.file);
    const t = MediaCacheKey(
        albumId: 'A', mediaId: 'M', epochTag: 7, asset: CacheAsset.thumb);
    expect(k.diskFilename, 'M.kec');
    expect(t.diskFilename, 'M.thumb.kec');
  });
}
