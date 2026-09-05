import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/data/storage/media_cache_key.dart';
import 'package:keepsy/data/storage/media_cache_manager.dart';
import 'package:keepsy/data/storage/media_plaintext_cache.dart';
import 'package:keepsy/data/storage/media_sealed_cache.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';
import 'package:keepsy/e2ee/media_record.dart';

import '../../secure_store/mock_secure_key_store.dart';

Uint8List _albumIdBytes() => Uint8List.fromList(List<int>.filled(16, 0xA1));
Uint8List _mk() => Uint8List.fromList(List<int>.filled(32, 0x42));
Uint8List _cacheKey() => Uint8List.fromList(List<int>.filled(32, 0x11));
Uint8List _plain() => Uint8List.fromList(List.generate(256, (i) => i & 0xFF));

// Solid color JPEG that decodes cleanly so prepareUpload runs the thumb gen path
Uint8List _syntheticJpegBytes({int w = 200, int h = 150}) {
  final image = img.Image(width: w, height: h);
  for (final p in image) {
    p.setRgb(120, 200, 80);
  }
  return img.encodeJpg(image, quality: 90);
}

String _uuidString(Uint8List bytes) {
  final s = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
      '-${s.substring(16, 20)}-${s.substring(20)}';
}

Future<AlbumKeyStore> _newAks() async {
  final s = MockSecureKeyStore();
  await s.initialize();
  final aks = AlbumKeyStore(s);
  await aks.initialize();
  await aks.installVerified(
      albumId: _albumIdBytes(), epoch: 0, mk: _mk(), backfill: false);
  return aks;
}

MediaRecord _recordFromEnvelope(UploadEnvelope env) => MediaRecord(
      id: _uuidString(env.mediaId),
      albumId: _uuidString(_albumIdBytes()),
      uploaderToken: 'dGVzdHRva2VuMTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMg==',
      wrapNonce: env.wrapNonce,
      wrapTagCT: env.wrapTagCT,
      epochTag: env.epoch,
      blobSize: env.blobSize,
      blobSha256: env.blobSha256,
      mediaType: env.mediaType,
      mimeType: env.mimeType,
      createdAt: DateTime.utc(2026, 6, 7),
      thumbWrapNonce: env.thumbWrapNonce,
      thumbWrapTagCT: env.thumbWrapTagCT,
      thumbSize: env.hasThumb ? env.thumbSize : null,
      thumbSha256: env.thumbSha256,
    );

class _FakeMediaApi implements MediaApiInterface {
  int listMediaCalls = 0;
  int requestDownloadURLCalls = 0;
  int downloadCiphertextCalls = 0;
  final List<MediaRecord> records = [];
  final Map<String, Uint8List> bytesByUrl = {};
  String? lastRequestedAsset;

  @override
  Future<List<MediaRecord>> listMedia(String albumId) async {
    listMediaCalls++;
    return records.where((r) => r.albumId == albumId).toList();
  }

  @override
  Future<String> requestDownloadURL(String albumId, String mediaId,
      {String asset = 'file'}) async {
    requestDownloadURLCalls++;
    lastRequestedAsset = asset;
    final key = asset == 'thumb' ? '$mediaId#thumb' : mediaId;
    return 'fake://$key';
  }

  @override
  Future<Uint8List> downloadCiphertext(String url,
      {int expectedBytes = 0, Future<String> Function()? refreshUrl}) async {
    downloadCiphertextCalls++;
    final b = bytesByUrl[url];
    if (b == null) throw StateError('no bytes for $url');
    return b;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tmp;
  late MediaSealedCache l2;
  late MediaPlaintextCache l1;
  late _FakeMediaApi api;
  late AlbumKeyStore aks;
  late MediaCacheManager mgr;
  late UploadEnvelope env;
  late MediaRecord record;
  late MediaCacheKey fileKey;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mcm_');
    l2 = await MediaSealedCache.open(
        rootDir: tmp, cacheRootKey: _cacheKey(), budgetBytes: 1024 * 1024);
    l1 = MediaPlaintextCache(budgetBytes: 1024 * 1024);
    api = _FakeMediaApi();
    aks = await _newAks();
    mgr = MediaCacheManager(plaintext: l1, ciphertext: l2, api: api, aks: aks);
    // Mint a real AEAD envelope so FileDecryptor's verify path is exercised.
    // 'video' : _plain() is raw bytes, not a decodable image (photo would now
    // fail closed). The cache round trip under test is media-type-agnostic
    env = await FilePipeline.prepareUpload(
      aks: aks,
      albumIdBytes: _albumIdBytes(),
      currentEpoch: 0,
      plaintext: _plain(),
      mediaType: 'video',
    );
    record = _recordFromEnvelope(env);
    fileKey = MediaCacheKey(
      albumId: record.albumId,
      mediaId: record.id,
      epochTag: 0,
      asset: CacheAsset.file,
    );
    api.records.add(record);
    api.bytesByUrl['fake://${record.id}'] = env.cipherBytes;
  });

  tearDown(() async {
    await l2.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('L1 hit short-circuits L2 and MediaApi', () async {
    l1.put(fileKey, _plain());
    final got = await mgr.getDecrypted(record, thumb: false);
    expect(got, equals(_plain()));
    expect(api.requestDownloadURLCalls, 0);
    expect(api.downloadCiphertextCalls, 0);
  });

  test('L2 warm hit returns plaintext without S3 and without useMk', () async {
    // L2 now holds sealed *plaintext* : seed it directly
    await l2.writeRecord(record);
    await l2.writeBlob(fileKey, _plain());
    final counter = _CountingAks(aks);
    final mgr2 = MediaCacheManager(
        plaintext: l1, ciphertext: l2, api: api, aks: counter);
    final got = await mgr2.getDecrypted(record, thumb: false);
    expect(got, equals(_plain()));
    expect(api.requestDownloadURLCalls, 0);
    expect(api.downloadCiphertextCalls, 0);
    expect(counter.useMkCalls, 0);
    expect(l1.get(fileKey), isNotNull);
  });

  test('cold miss fetches S3, decrypts, and seals plaintext into L2', () async {
    final got = await mgr.getDecrypted(record, thumb: false);
    expect(got, equals(_plain()));
    expect(api.requestDownloadURLCalls, 1);
    expect(api.downloadCiphertextCalls, 1);
    // L2 now holds the decrypted plaintext (sealed under cache_root_key)
    expect(await l2.readBlob(fileKey), equals(_plain()));
    expect(await l2.readRecord(record.id), isNotNull);
    expect(l1.get(fileKey), equals(_plain()));
  });

  test('acceptNewMedia warms ONLY the thumb, never the full file', () async {
    // Thumbed envelope : a real JPEG so prepareUpload emits a thumb cipher
    final tenv = await FilePipeline.prepareUpload(
      aks: aks,
      albumIdBytes: _albumIdBytes(),
      currentEpoch: 0,
      plaintext: _syntheticJpegBytes(),
      mediaType: 'photo',
      mimeType: 'image/jpeg',
    );
    expect(tenv.hasThumb, isTrue, reason: 'fixture must have a thumb');
    final trecord = _recordFromEnvelope(tenv);
    api.records.add(trecord);
    api.bytesByUrl['fake://${trecord.id}'] = tenv.cipherBytes;
    api.bytesByUrl['fake://${trecord.id}#thumb'] = tenv.thumbCipherBytes!;

    final counter = _CountingAks(aks);
    final mgr2 = MediaCacheManager(
        plaintext: l1, ciphertext: l2, api: api, aks: counter);
    await mgr2.acceptNewMedia(trecord);

    final thumbKey = MediaCacheKey(
        albumId: trecord.albumId,
        mediaId: trecord.id,
        epochTag: 0,
        asset: CacheAsset.thumb);
    final fileKey2 = MediaCacheKey(
        albumId: trecord.albumId,
        mediaId: trecord.id,
        epochTag: 0,
        asset: CacheAsset.file);
    // thumb warmed (tiny, keeps the grid instant) ...
    expect(await l2.readBlob(thumbKey), isNotNull);
    expect(counter.useMkCalls, 1);
    // ... but the full file is NOT instantly pulled : it loads lazily
    // only when the user actually opens the photo (EncryptedImage)
    expect(await l2.readBlob(fileKey2), isNull);
    expect(api.lastRequestedAsset, 'thumb');
  });

  test('acceptNewMedia on a thumbless record fetches nothing eagerly',
      () async {
    // Legacy / no thumb media : the full file loads lazily on view, not on
    // arrival. Record is still indexed so listMedia ordering etc. is unaffected
    final counter = _CountingAks(aks);
    final mgr2 = MediaCacheManager(
        plaintext: l1, ciphertext: l2, api: api, aks: counter);
    await mgr2.prefetch(record.albumId, record.id);
    expect(await l2.readBlob(fileKey), isNull);
    expect(api.requestDownloadURLCalls, 0);
    expect(counter.useMkCalls, 0);
    expect(await l2.readRecord(record.id), isNotNull);
  });

  test('seedFromUpload seals plaintext into L2', () async {
    await mgr.seedFromUpload(albumId: record.albumId, env: env);
    final mid = env.mediaIdString;
    final k = MediaCacheKey(
        albumId: record.albumId,
        mediaId: mid,
        epochTag: env.epoch,
        asset: CacheAsset.file);
    expect(l1.get(k), equals(env.filePlaintext));
    expect(await l2.readBlob(k), equals(env.filePlaintext));
  });

  test('invalidate drops both layers', () async {
    l1.put(fileKey, _plain());
    await l2.writeRecord(record);
    await l2.writeBlob(fileKey, _plain());
    await mgr.invalidate(record.id);
    expect(l1.get(fileKey), isNull);
    expect(await l2.readBlob(fileKey), isNull);
    expect(await l2.readRecord(record.id), isNull);
  });

  test('clearAlbum drops both layers for that album', () async {
    l1.put(fileKey, _plain());
    await l2.writeRecord(record);
    await l2.writeBlob(fileKey, _plain());
    await mgr.clearAlbum(record.albumId);
    expect(l1.get(fileKey), isNull);
    expect(await l2.readBlob(fileKey), isNull);
  });
}

// Counts useMk calls so the warm-hit "no-MK" guarantee + the cold-fill
// "exactly one MK" guarantee are testable. Delegates every other call to the
// real instance so installVerified + _present stay consistent
class _CountingAks implements AlbumKeyStore {
  final AlbumKeyStore _inner;
  int useMkCalls = 0;
  _CountingAks(this._inner);

  @override
  Future<T> useMk<T>(
      Uint8List albumId, int epoch, Future<T> Function(Uint8List) fn) async {
    useMkCalls++;
    return _inner.useMk(albumId, epoch, fn);
  }

  @override
  Future<int> latestEpoch(Uint8List albumId) => _inner.latestEpoch(albumId);

  @override
  Future<List<int>> presentEpochs(Uint8List albumId) =>
      _inner.presentEpochs(albumId);

  @override
  Future<void> initialize() => _inner.initialize();

  @override
  Future<void> install(Uint8List albumId, int epoch, Uint8List mk) =>
      _inner.install(albumId, epoch, mk);

  @override
  Future<void> installVerified({
    required Uint8List albumId,
    required int epoch,
    required Uint8List mk,
    required bool backfill,
  }) =>
      _inner.installVerified(
          albumId: albumId, epoch: epoch, mk: mk, backfill: backfill);

  // ignore: invalid_use_of_visible_for_testing_member
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
