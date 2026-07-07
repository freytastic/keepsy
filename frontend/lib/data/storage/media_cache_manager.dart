import 'dart:typed_data';

import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/file_decryptor.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';
import 'package:keepsy/e2ee/media_record.dart';

import 'media_cache_key.dart';
import 'media_plaintext_cache.dart';
import 'media_sealed_cache.dart';

// Composes L1 (RAM plaintext) + L2 (disk plaintext sealed under cache_root_key)
// + L3 (S3 via MediaApi). The warm L2 path is pure cache_root_key CPU : no
// useMk, no AndroidKeyStore IPC. useMk is paid once per photo on the L3
// cold-fill path (the DEK unwrap), then the plaintext is sealed into L2 so
// every later read stays warm

class MediaCacheManager {
  final MediaPlaintextCache _l1;
  final MediaSealedCache _l2;
  final MediaApiInterface _api;
  final AlbumKeyStore _aks;

  // In flight dedupe : two callers asking for the same key collapse into one
  // operation. _inflightPt covers the full path, _inflightCt covers just the
  // L3 fetch + decrypt + seal (saves a redundant S3 GET + useMk when a widget
  // races acceptNewMedia for the same blob)
  final Map<MediaCacheKey, Future<Uint8List>> _inflightPt = {};
  final Map<MediaCacheKey, Future<Uint8List>> _inflightCt = {};

  MediaCacheManager({
    required MediaPlaintextCache plaintext,
    required MediaSealedCache ciphertext,
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

    final f = _resolveAndStore(r, k, thumb: thumb);
    _inflightPt[k] = f;
    try {
      return await f;
    } finally {
      _inflightPt.remove(k);
    }
  }

  Future<Uint8List> _resolveAndStore(MediaRecord r, MediaCacheKey k,
      {required bool thumb}) async {
    // Warm L2 hit returns plaintext directly : no FileDecryptor, no useMk
    final disk = await _l2.readBlob(k);
    final pt = disk ?? await _coldFill(r, k, thumb: thumb);
    _l1.put(k, pt);
    return pt;
  }

  // L3 cold fill : fetch S3 ciphertext, unwrap+decrypt via FileDecryptor (the
  // one useMk per photo), then seal the plaintext into L2. Concurrent callers
  // for the same key collapse to a single fetch+decrypt via _inflightCt
  Future<Uint8List> _coldFill(MediaRecord r, MediaCacheKey k,
      {required bool thumb}) async {
    final pending = _inflightCt[k];
    if (pending != null) return pending;
    final f = _doColdFill(r, k, thumb: thumb);
    _inflightCt[k] = f;
    try {
      return await f;
    } finally {
      _inflightCt.remove(k);
    }
  }

  Future<Uint8List> _doColdFill(MediaRecord r, MediaCacheKey k,
      {required bool thumb}) async {
    final tag = k.asset == CacheAsset.thumb ? 'thumb' : 'file';
    final url = await _api.requestDownloadURL(k.albumId, k.mediaId, asset: tag);
    final cipher = await _api.downloadCiphertext(url);
    final pt = await _decrypt(r, thumb: thumb, ciphertext: cipher);
    await _l2.writeRecord(r);
    await _l2.writeBlob(k, pt);
    return pt;
  }

  // FileDecryptor takes a download closure : feed it the cached ciphertext so
  // the existing AAD + AEAD + SHA256 verify path runs unchanged. presignedUrl
  // is never actually fetched : the stub ignores it
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

  // Warms L2 on e2ee.media_added with ONLY the thumbnail (~20KB) so the grid
  // tile is an instant plaintext hit when the album opens, at one useMk. The
  // full file is deliberately NOT prefetched : it loads
  // lazily on demand the first time the user opens the photo (EncryptedImage)
  // The WS payload embeds the full record so we skip the listMedia roundtrip
  Future<void> acceptNewMedia(MediaRecord r) async {
    try {
      await _l2.writeRecord(r);
      if (!r.hasThumb) return;
      final thumbK = MediaCacheKey(
        albumId: r.albumId,
        mediaId: r.id,
        epochTag: r.epochTag,
        asset: CacheAsset.thumb,
      );
      if (await _l2.readBlob(thumbK) == null) {
        await _coldFill(r, thumbK, thumb: true);
      }
    } catch (_) {}
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
    } catch (_) {}
  }

  // Uploader side seed : after PUT+confirm the plaintext is still in process
  // memory. Seal it into L2 + put in L1 so the grid rebuild hits cache (~0ms)
  // instead of paying L3 + decrypt for content the uploader just produced. No
  // useMk : we already hold the plaintext
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
    await _l2.writeBlob(fileK, env.filePlaintext);
    if (env.hasThumb && env.thumbPlaintext != null) {
      final thumbK = MediaCacheKey(
        albumId: albumId,
        mediaId: mid,
        epochTag: env.epoch,
        asset: CacheAsset.thumb,
      );
      _l1.put(thumbK, env.thumbPlaintext!);
      await _l2.writeBlob(thumbK, env.thumbPlaintext!);
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
