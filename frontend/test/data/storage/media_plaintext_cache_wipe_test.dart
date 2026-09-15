import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/storage/media_cache_key.dart';
import 'package:keepsy/data/storage/media_plaintext_cache.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';

void main() {
  test('a wipe zeroes plaintext instead of only dropping it', () {
    final cache = MediaPlaintextCache();
    final bytes = Uint8List.fromList([1, 2, 3]);
    cache.put(
        const MediaCacheKey(
            albumId: 'a', mediaId: 'm', epochTag: 0, asset: CacheAsset.thumb),
        bytes);
    cache.wipe();
    expect(bytes, [0, 0, 0]);
    expect(cache.count, 0);
  });

  test('a wiped sealed photo loses its keys and its plaintext', () {
    final media = EncryptedMedia(
      mediaId: Uint8List(16),
      cipherBytes: Uint8List(4),
      blobSha256: Uint8List(32),
      dek: Uint8List.fromList(List.filled(32, 7)),
      mediaType: 'photo',
      mimeType: 'image/jpeg',
      thumbDek: Uint8List.fromList(List.filled(32, 7)),
      filePlaintext: Uint8List.fromList([9, 9]),
      thumbPlaintext: Uint8List.fromList([9]),
    );
    media.zeroAll();
    for (final b in [
      media.dek,
      media.thumbDek!,
      media.filePlaintext!,
      media.thumbPlaintext!
    ]) {
      expect(b.every((x) => x == 0), isTrue);
    }
  });
}
