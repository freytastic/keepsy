import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/data/storage/media_cache_key.dart';
import 'package:keepsy/data/storage/media_cache_manager.dart';
import 'package:keepsy/data/storage/media_ciphertext_cache.dart';
import 'package:keepsy/data/storage/media_plaintext_cache.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';
import 'package:keepsy/e2ee/media_record.dart';

import '../../secure_store/mock_secure_key_store.dart';

Uint8List _albumIdBytes() => Uint8List.fromList(List<int>.filled(16, 0xA1));
Uint8List _mediaIdBytes() => Uint8List.fromList(List<int>.filled(16, 0xB2));
Uint8List _mk() => Uint8List.fromList(List<int>.filled(32, 0x42));

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
      createdAt: DateTime.utc(2026, 6, 3),
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
  Future<Uint8List> downloadCiphertext(String url) async {
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
  late MediaCiphertextCache l2;
  late MediaPlaintextCache l1;
  late _FakeMediaApi api;
  late AlbumKeyStore aks;
  late MediaCacheManager mgr;
  late UploadEnvelope env;
  late MediaRecord record;
  late MediaCacheKey fileKey;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mcm_');
    l2 =
        await MediaCiphertextCache.open(rootDir: tmp, budgetBytes: 1024 * 1024);
    l1 = MediaPlaintextCache(budgetBytes: 1024 * 1024);
    api = _FakeMediaApi();
    aks = await _newAks();
    mgr = MediaCacheManager(plaintext: l1, ciphertext: l2, api: api, aks: aks);
    // Mint a real AEAD envelope so FileDecryptor's verify path is exercised
    env = await FilePipeline.prepareUpload(
      aks: aks,
      albumIdBytes: _albumIdBytes(),
      currentEpoch: 0,
      plaintext: Uint8List.fromList(List.generate(256, (i) => i & 0xFF)),
      mediaType: 'photo',
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
    final plaintext = Uint8List.fromList(List.generate(256, (i) => i & 0xFF));
    l1.put(fileKey, plaintext);
    final got = await mgr.getDecrypted(record, thumb: false);
    expect(got, equals(plaintext));
    expect(api.requestDownloadURLCalls, 0);
    expect(api.downloadCiphertextCalls, 0);
  });

  test('L2 hit decrypts without S3', () async {
    await l2.writeRecord(record);
    await l2.writeBlob(fileKey, env.cipherBytes);
    final got = await mgr.getDecrypted(record, thumb: false);
    final expected = Uint8List.fromList(List.generate(256, (i) => i & 0xFF));
    expect(got, equals(expected));
    expect(api.requestDownloadURLCalls, 0);
    expect(api.downloadCiphertextCalls, 0);
    // L1 now has the plaintext
    expect(l1.get(fileKey), isNotNull);
  });

  test('cold miss populates both layers', () async {
    final got = await mgr.getDecrypted(record, thumb: false);
    final expected = Uint8List.fromList(List.generate(256, (i) => i & 0xFF));
    expect(got, equals(expected));
    expect(api.requestDownloadURLCalls, 1);
    expect(api.downloadCiphertextCalls, 1);
    expect(await l2.readBlob(fileKey), equals(env.cipherBytes));
    expect(await l2.readRecord(record.id), isNotNull);
    expect(l1.get(fileKey), equals(expected));
  });

  test('prefetch warms L2 without calling useMk', () async {
    // Wire a counting AKS wrapper to assert useMk is NEVER touched
    final counter = _CountingAks(aks);
    final mgr2 = MediaCacheManager(
        plaintext: l1, ciphertext: l2, api: api, aks: counter);
    await mgr2.prefetch(record.albumId, record.id);
    expect(await l2.readBlob(fileKey), equals(env.cipherBytes));
    expect(await l2.readRecord(record.id), isNotNull);
    expect(counter.useMkCalls, 0);
  });

  test('invalidate drops both layers', () async {
    final plaintext = Uint8List.fromList(List.generate(256, (i) => i & 0xFF));
    l1.put(fileKey, plaintext);
    await l2.writeRecord(record);
    await l2.writeBlob(fileKey, env.cipherBytes);
    await mgr.invalidate(record.id);
    expect(l1.get(fileKey), isNull);
    expect(await l2.readBlob(fileKey), isNull);
    expect(await l2.readRecord(record.id), isNull);
  });

  test('clearAlbum drops both layers for that album', () async {
    final plaintext = Uint8List.fromList(List.generate(256, (i) => i & 0xFF));
    l1.put(fileKey, plaintext);
    await l2.writeRecord(record);
    await l2.writeBlob(fileKey, env.cipherBytes);
    await mgr.clearAlbum(record.albumId);
    expect(l1.get(fileKey), isNull);
    expect(await l2.readBlob(fileKey), isNull);
  });
}

// Counts useMk calls so prefetch's "no-MK" guarantee is testable. Delegates
// every other AlbumKeyStore call to the real instance so installVerified +
// _present stay consistent
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
