import 'dart:typed_data';

import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/file_decryptor.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';
import 'package:keepsy/e2ee/media_record.dart';

import 'package:keepsy/diagnostics/trace.dart';

import 'media_cache_key.dart';
import 'media_plaintext_cache.dart';
import 'media_sealed_cache.dart';

// Keeps plaintext in RAM and sealed plaintext on disk after the first MK unwrap

class MediaCacheManager {
  final MediaPlaintextCache _l1;
  final MediaSealedCache _l2;
  final MediaApiInterface _api;
  final AlbumKeyStore _aks;

  // Separate in-flight maps deduplicate the full read and cold-fill paths
  final Map<MediaCacheKey, Future<Uint8List>> _inflightPt = {};
  final Map<MediaCacheKey, Future<Uint8List>> _inflightCt = {};
  bool _closed = false;

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
    if (_closed) throw StateError('media cache is shut down');
    final k = MediaCacheKey(
      albumId: r.albumId,
      mediaId: r.id,
      epochTag: r.epochTag,
      asset: thumb ? CacheAsset.thumb : CacheAsset.file,
    );

    final ram = _l1.get(k);
    if (ram != null) {
      Trace.event('media.get', fields: {..._keyFields(k), 'tier': 'l1'});
      return ram;
    }

    final pending = _inflightPt[k];
    if (pending != null) {
      Trace.event('media.get', fields: {..._keyFields(k), 'tier': 'dedupe_pt'});
      return pending;
    }

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
    final disk = await Trace.measure<Uint8List?>(
      'media.l2Read',
      () => _l2.readBlob(k),
      fields: _keyFields(k),
      endFields: (result) => {
        'hit': result != null,
        'bytes': result?.length ?? 0,
      },
    );
    if (disk != null) {
      Trace.event('media.get', fields: {..._keyFields(k), 'tier': 'l2'});
    }
    final pt = disk ?? await _coldFill(r, k, thumb: thumb);
    if (!_closed) _l1.put(k, pt);
    return pt;
  }

  static Map<String, Object?> _keyFields(MediaCacheKey k) => {
        'album': Trace.id(k.albumId),
        'media': Trace.id(k.mediaId),
        'epoch': k.epochTag,
        'asset': k.asset == CacheAsset.thumb ? 'thumb' : 'file',
      };

  // Cold fills perform one fetch, MK unwrap and sealed-cache write per key
  Future<Uint8List> _coldFill(MediaRecord r, MediaCacheKey k,
      {required bool thumb}) async {
    final pending = _inflightCt[k];
    if (pending != null) {
      Trace.event('media.get', fields: {..._keyFields(k), 'tier': 'dedupe_ct'});
      return pending;
    }
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
    Trace.event('media.get', fields: {..._keyFields(k), 'tier': 'l3'});
    final span = Trace.start('media.coldFill', fields: _keyFields(k));
    final tag = k.asset == CacheAsset.thumb ? 'thumb' : 'file';
    try {
      final url = await Trace.measure<String>(
        'media.presign',
        () => _api.requestDownloadURL(k.albumId, k.mediaId, asset: tag),
        fields: _keyFields(k),
        endFields: (result) => {'host': Trace.url(result)},
      );

      final expected =
          k.asset == CacheAsset.thumb ? (r.thumbSize ?? 0) : r.blobSize;
      final cipher = await Trace.measure<Uint8List>(
        'media.download',
        () => _api.downloadCiphertext(
          url,
          expectedBytes: expected,
          // Refresh the presigned URL between retries
          refreshUrl: () =>
              _api.requestDownloadURL(k.albumId, k.mediaId, asset: tag),
        ),
        fields: _keyFields(k),
        endFields: (result) => {'bytes': result.length},
      );

      final pt = await Trace.measure<Uint8List>(
        'media.decrypt',
        () => _decrypt(r, thumb: thumb, ciphertext: cipher),
        fields: _keyFields(k),
        endFields: (result) => {'bytes': result.length},
      );

      await Trace.measure<void>(
        'media.l2Write',
        () async {
          await _l2.writeRecord(r);
          await _l2.writeBlob(k, pt);
        },
        fields: _keyFields(k),
        endFields: (_) => {'bytes': pt.length},
      );

      span.end(fields: {'bytes': pt.length});
      return pt;
    } catch (e) {
      span.fail(e is FileDecryptError ? e.reason : e.runtimeType.toString());
      rethrow;
    }
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

  // Realtime events warm only thumbnails and leave full photos on demand
  Future<void> acceptNewMedia(MediaRecord r) async {
    if (_closed) return;
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

  // Seed caches from upload plaintext without another fetch or MK unwrap
  // Skip full size L1 inserts during batches to avoid evicting visible media
  Future<void> seedFromUpload({
    required String albumId,
    required UploadEnvelope env,
    required String uploaderToken,
    bool fullToL1 = true,
  }) async {
    if (_closed) return;
    final mid = env.mediaIdString;
    // Persist the record before its blobs so uploads can render offline
    await _l2.writeRecord(MediaRecord(
      id: mid,
      albumId: albumId,
      uploaderToken: uploaderToken,
      wrapNonce: env.wrapNonce,
      wrapTagCT: env.wrapTagCT,
      epochTag: env.epoch,
      blobSize: env.blobSize,
      blobSha256: env.blobSha256,
      mediaType: env.mediaType,
      mimeType: env.mimeType,
      // A later listing reconciles the hour-precise server order
      createdAt: DateTime.now().toUtc(),
      thumbWrapNonce: env.thumbWrapNonce,
      thumbWrapTagCT: env.thumbWrapTagCT,
      thumbSize: env.hasThumb ? env.thumbSize : null,
      thumbSha256: env.thumbSha256,
    ));
    await Trace.measure<void>(
      'media.seedUpload',
      () async {
        final fileK = MediaCacheKey(
          albumId: albumId,
          mediaId: mid,
          epochTag: env.epoch,
          asset: CacheAsset.file,
        );
        final file = env.filePlaintext;
        if (file != null) {
          if (fullToL1 && !_closed) _l1.put(fileK, file);
          await _l2.writeBlob(fileK, file);
        }
        if (env.hasThumb && env.thumbPlaintext != null) {
          final thumbK = MediaCacheKey(
            albumId: albumId,
            mediaId: mid,
            epochTag: env.epoch,
            asset: CacheAsset.thumb,
          );
          if (!_closed) _l1.put(thumbK, env.thumbPlaintext!);
          await _l2.writeBlob(thumbK, env.thumbPlaintext!);
        }
      },
      fields: {
        'album': Trace.id(albumId),
        'media': Trace.id(mid),
        'file_bytes': env.filePlaintext?.length ?? 0,
        'thumb_bytes': env.thumbPlaintext?.length ?? 0,
      },
    );
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

  // Refuses wipe success while a download may still write plaintext
  Future<void> shutdown({Duration wait = const Duration(seconds: 20)}) async {
    _closed = true;
    try {
      final running = [..._inflightPt.values, ..._inflightCt.values];
      await Future.wait(running.map((f) => f.then((_) {}, onError: (_) {})))
          .timeout(wait);
    } finally {
      _l1.wipe();
    }
  }
}
