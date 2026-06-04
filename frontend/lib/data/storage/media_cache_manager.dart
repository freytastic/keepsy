import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/file_decryptor.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';
import 'package:keepsy/e2ee/media_record.dart';

import 'media_cache_key.dart';
import 'media_ciphertext_cache.dart';
import 'media_plaintext_cache.dart';

// Composes L1 (RAM plaintext) + L2 (disk ciphertext + sqlite records.db) +
// L3 (S3 via MediaApi). Read path orchestrator for the encrypted_image and
// encrypted_thumbnail widgets. Prefetch is a side door : warms L2 only,
// never touches MK so background sync doesnt wake AndroidKeyStore

class MediaCacheManager {
  final MediaPlaintextCache _l1;
  final MediaCiphertextCache _l2;
  final MediaApiInterface _api;
  final AlbumKeyStore _aks;

  // In flight dedupe : two callers asking for the same key collapse into
  // one operation. _inflightPt covers the full decrypt path (saves a
  // decrypt round on the second caller). _inflightCt covers just the L3
  // fetch + L2 write (saves a redundant S3 GET when a widget races
  // acceptNewMedia for the same blob)
  final Map<MediaCacheKey, Future<Uint8List>> _inflightPt = {};
  final Map<MediaCacheKey, Future<Uint8List>> _inflightCt = {};

  MediaCacheManager({
    required MediaPlaintextCache plaintext,
    required MediaCiphertextCache ciphertext,
    required MediaApiInterface api,
    required AlbumKeyStore aks,
  })  : _l1 = plaintext,
        _l2 = ciphertext,
        _api = api,
        _aks = aks;

  Future<Uint8List> getDecrypted(MediaRecord r, {required bool thumb}) async {
    final k = MediaCacheKey(
      albumId: r.albumId,
      mediaId: r.id,
      epochTag: r.epochTag,
      asset: thumb ? CacheAsset.thumb : CacheAsset.file,
    );

    final ram = _l1.get(k);
    if (ram != null) return ram;

    final pending = _inflightPt[k];
    if (pending != null) return pending;

    final f = _resolveDecryptAndStore(r, k, thumb: thumb);
    _inflightPt[k] = f;
    try {
      return await f;
    } finally {
      _inflightPt.remove(k);
    }
  }

  Future<Uint8List> _resolveDecryptAndStore(MediaRecord r, MediaCacheKey k,
      {required bool thumb}) async {
    final disk = await _l2.readBlob(k);
    Uint8List cipher;
    if (disk != null) {
      cipher = disk;
    } else {
      // writeRecord before _ensureCiphertext so writeBlob doesnt fall
      // back to inserting a placeholder json row
      await _l2.writeRecord(r);
      cipher = await _ensureCiphertext(k);
    }

    final pt = await _decrypt(r, thumb: thumb, ciphertext: cipher);
    _l1.put(k, pt);
    return pt;
  }

  // Fetches ciphertext from S3 + writes to L2. Concurrent callers for the
  // same key collapse to a single fetch + write via _inflightCt
  Future<Uint8List> _ensureCiphertext(MediaCacheKey k) async {
    final pending = _inflightCt[k];
    if (pending != null) return pending;
    final f = _l3FetchAndWriteL2(k);
    _inflightCt[k] = f;
    try {
      return await f;
    } finally {
      _inflightCt.remove(k);
    }
  }

  Future<Uint8List> _l3FetchAndWriteL2(MediaCacheKey k) async {
    final tag = k.asset == CacheAsset.thumb ? 'thumb' : 'file';
    final url = await _api.requestDownloadURL(k.albumId, k.mediaId, asset: tag);
    final cipher = await _api.downloadCiphertext(url);
    await _l2.writeBlob(k, cipher);
    return cipher;
  }

  // FileDecryptor takes a download closure : feed it the cached bytes so the
  // existing AAD + AEAD + SHA256 verify path runs unchanged. presignedUrl is
  // never actually fetched : the stub ignores it
  Future<Uint8List> _decrypt(MediaRecord r,
      {required bool thumb, required Uint8List ciphertext}) async {
    Future<Uint8List> stub(String _) async => ciphertext;
    if (thumb) {
      return FileDecryptor.downloadAndDecryptThumb(
          aks: _aks, record: r, presignedUrl: 'cache://', download: stub);
    }
    return FileDecryptor.downloadAndDecrypt(
        aks: _aks, record: r, presignedUrl: 'cache://', download: stub);
  }

  // Warms L2 ONLY : downloads ciphertext + persists the MediaRecord row but
  // never invokes useMk. Called by main.dart's WS dispatcher on
  // e2ee.media_added so the new tile is cache-warm by the time the user
  // opens the album (zero S3 + zero AndroidKeyStore on first render)
  // Fast path : the WS payload now embeds the full record so we skip the
  // listMedia roundtrip. Falls back to the slow path (prefetch by id only)
  // when an older server emits no record block
  Future<void> acceptNewMedia(MediaRecord r) async {
    try {
      await _l2.writeRecord(r);
      final fileK = MediaCacheKey(
        albumId: r.albumId,
        mediaId: r.id,
        epochTag: r.epochTag,
        asset: CacheAsset.file,
      );
      if (await _l2.readBlob(fileK) == null) {
        await _ensureCiphertext(fileK);
      }
      if (r.hasThumb) {
        final thumbK = MediaCacheKey(
          albumId: r.albumId,
          mediaId: r.id,
          epochTag: r.epochTag,
          asset: CacheAsset.thumb,
        );
        if (await _l2.readBlob(thumbK) == null) {
          await _ensureCiphertext(thumbK);
        }
      }
    } catch (e, s) {
      developer.log('acceptNewMedia failed',
          name: 'keepsy.cache', error: e, stackTrace: s);
    }
  }

  // Fallback : pre-Fix-5 path, listMedia + dispatch by id. kept for callers
  // that only have (albumId, mediaId) on hand
  Future<void> prefetch(String albumId, String mediaId) async {
    try {
      final all = await _api.listMedia(albumId);
      for (final x in all) {
        if (x.id == mediaId) {
          await acceptNewMedia(x);
          return;
        }
      }
    } catch (e, s) {
      developer.log('prefetch failed',
          name: 'keepsy.cache', error: e, stackTrace: s);
    }
  }

  // Uploader side seed : after PUT+confirm the bytes are still in process
  // memory. Putting them into L1 + L2 means the grid rebuild that follows
  // _loadMedia hits L1 (~0ms) instead of paying ~150ms L3 + decrypt for
  // content the uploader literally just produced. Plaintext lives only in L1
  Future<void> seedFromUpload({
    required String albumId,
    required UploadEnvelope env,
  }) async {
    final mid = env.mediaIdString;
    final fileK = MediaCacheKey(
      albumId: albumId,
      mediaId: mid,
      epochTag: env.epoch,
      asset: CacheAsset.file,
    );
    _l1.put(fileK, env.filePlaintext);
    await _l2.writeBlob(fileK, env.cipherBytes);
    if (env.hasThumb &&
        env.thumbPlaintext != null &&
        env.thumbCipherBytes != null) {
      final thumbK = MediaCacheKey(
        albumId: albumId,
        mediaId: mid,
        epochTag: env.epoch,
        asset: CacheAsset.thumb,
      );
      _l1.put(thumbK, env.thumbPlaintext!);
      await _l2.writeBlob(thumbK, env.thumbCipherBytes!);
    }
  }

  Future<void> invalidate(String mediaId) async {
    _l1.removeByMediaId(mediaId);
    await _l2.invalidate(mediaId);
  }

  Future<void> clearAlbum(String albumId) async {
    _l1.clearAlbum(albumId);
    await _l2.clearAlbum(albumId);
  }

  void onAppPaused() {
    _l1.clearAll();
  }

  Future<void> clearAll() async {
    _l1.clearAll();
    await _l2.clearAll();
  }
}
