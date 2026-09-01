import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/data/models/album_summary.dart';
import 'package:keepsy/data/storage/media_sealed_cache.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/ui/shelf/shelf_covers_impl.dart';

import '../secure_store/mock_secure_key_store.dart';

class FakeApi implements MediaApiInterface {
  final List<String> downloads = [];
  int urlCalls = 0;
  Completer<void>? gate;

  @override
  Future<List<MediaRecord>> listMedia(String albumId) async => [];

  @override
  Future<String> requestDownloadURL(String albumId, String mediaId,
      {String asset = 'file'}) async {
    urlCalls++;
    downloads.add('$mediaId:$asset');
    return 'https://example.test/$mediaId';
  }

  Uint8List cipher = Uint8List(0);

  @override
  Future<Uint8List> downloadCiphertext(String url) async {
    await gate?.future;
    return cipher;
  }
}

PreviewMedia _preview(String id) => PreviewMedia(
      mediaId: id,
      epochTag: 0,
      thumbWrapNonce: Uint8List(12),
      thumbWrapTagCT: Uint8List(48),
      thumbSize: 10,
      thumbSha256: Uint8List(32),
    );

final _albumIdBytes = Uint8List.fromList(List<int>.filled(16, 0xA1));
final _realAlbumId = _uuidString(_albumIdBytes);

Uint8List _jpeg() {
  final image = img.Image(width: 64, height: 48);
  for (final p in image) {
    p.setRgb(120, 200, 80);
  }
  return img.encodeJpg(image, quality: 90);
}

String _uuidString(Uint8List b) {
  final s = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
      '-${s.substring(16, 20)}-${s.substring(20)}';
}

// Real encryption keeps cache write assertions from passing on decrypt failure
Future<({AlbumKeyStore aks, PreviewMedia preview, Uint8List cipher})>
    _realCover() async {
  final store = MockSecureKeyStore();
  await store.initialize();
  final aks = AlbumKeyStore(store);
  await aks.initialize();
  await aks.installVerified(
      albumId: _albumIdBytes,
      epoch: 0,
      mk: Uint8List.fromList(List<int>.filled(32, 0x42)),
      backfill: false);

  final env = await FilePipeline.prepareUpload(
    aks: aks,
    albumIdBytes: _albumIdBytes,
    currentEpoch: 0,
    plaintext: _jpeg(),
    mediaType: 'photo',
  );
  return (
    aks: aks,
    cipher: env.thumbCipherBytes!,
    preview: PreviewMedia(
      mediaId: _uuidString(env.mediaId),
      epochTag: env.epoch,
      thumbWrapNonce: env.thumbWrapNonce!,
      thumbWrapTagCT: env.thumbWrapTagCT!,
      thumbSize: env.thumbSize,
      thumbSha256: env.thumbSha256!,
    ),
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tmp;
  late MediaSealedCache l2;
  late FakeApi api;
  late ShelfCoversImpl covers;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('covers_');
    l2 = await MediaSealedCache.open(
        rootDir: tmp,
        cacheRootKey: Uint8List.fromList(List<int>.filled(32, 7)));
    api = FakeApi();
    covers = ShelfCoversImpl(
      sealedCache: l2,
      api: api,
      albumKeys: AlbumKeyStore(MockSecureKeyStore()),
    );
  });

  tearDown(() async {
    await l2.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('the cover registry records all three, and only the cover is fetched',
      () async {
    covers.ensureCover('a1', [_preview('m1'), _preview('m2'), _preview('m3')]);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(await l2.coversFor('a1'), ['m1', 'm2', 'm3'],
        reason: 'eviction reads this, so all three must be pinned');
    expect(api.downloads, ['m1:thumb'],
        reason: 'the riffle pair waits for the gesture');
  });

  test('a hold fetches the two behind it', () async {
    final preview = [_preview('m1'), _preview('m2'), _preview('m3')];
    covers.ensureCover('a1', preview);
    covers.ensureRiffle('a1', preview);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(api.downloads, containsAll(['m1:thumb', 'm2:thumb', 'm3:thumb']));
  });

  test('a failed cover is not retried on every rebuild', () async {
    covers.ensureCover('a1', [_preview('m1')]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final first = api.urlCalls;

    for (var i = 0; i < 5; i++) {
      covers.ensureCover('a1', [_preview('m1')]);
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(api.urlCalls, first);
  });

  test('new preview media replaces the pinned covers', () async {
    covers.ensureCover('a1', [_preview('m1'), _preview('m2')]);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    covers.ensureCover('a1', [_preview('m9'), _preview('m1')]);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(await l2.coversFor('a1'), ['m9', 'm1']);
    expect(api.downloads, contains('m9:thumb'),
        reason: 'a slot keyed cache would have served the stale cover');
  });

  test('forget drops one album and leaves the others alone', () async {
    covers.ensureCover('a1', [_preview('m1')]);
    covers.ensureCover('a2', [_preview('m2')]);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await covers.forget('a1');
    expect(covers.bytes('a1', 0), isNull);
    expect(api.downloads, contains('m2:thumb'),
        reason: 'wiping one album must not cancel another albums covers');
  });

  test('forget waits for a load already in flight', () async {
    api.gate = Completer<void>();
    covers.ensureCover('a1', [_preview('m1')]);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final wiped = covers.forget('a1');
    var done = false;
    unawaited(wiped.then((_) => done = true));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(done, isFalse,
        reason: 'the caller must not delete cache files under a live load');

    api.gate!.complete();
    await wiped;
    expect(covers.bytes('a1', 0), isNull,
        reason: 'plaintext must not come back after the wipe');
  });

  group('with a cover that really decrypts', () {
    late PreviewMedia real;
    late ShelfCoversImpl live;

    setUp(() async {
      final c = await _realCover();
      real = c.preview;
      api.cipher = c.cipher;
      live = ShelfCoversImpl(sealedCache: l2, api: api, albumKeys: c.aks);
    });

    test('the fixture actually decrypts, or nothing below means anything',
        () async {
      live.ensureCover(_realAlbumId, [real]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(live.bytes(_realAlbumId, 0), isNotNull,
          reason: 'a failing decrypt would make every assertion here vacuous');
      expect(await l2.readRecord(real.mediaId), isNotNull);
    });

    test('a wiped album is not written back into the sealed cache', () async {
      api.gate = Completer<void>();
      live.ensureCover(_realAlbumId, [real]);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final wiped = live.forget(_realAlbumId);
      api.gate!.complete();
      await wiped;
      await l2.clearAlbum(_realAlbumId);

      expect(live.bytes(_realAlbumId, 0), isNull);
      expect(await l2.readRecord(real.mediaId), isNull,
          reason: 'the load was past its download when the wipe landed');
      expect(await l2.coversFor(_realAlbumId), isEmpty);
    });

    Future<bool> heldInRam(PreviewMedia p) async {
      live.ensureCover(_realAlbumId, [p]);
      // Read before yielding to detect only resident plaintext
      final held = live.bytes(_realAlbumId, 0) != null;
      await live.forget(_realAlbumId);
      return held;
    }

    test('forget wipes covers the album no longer shows', () async {
      final c2 = await _realCover();
      live.ensureCover(_realAlbumId, [real]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(live.bytes(_realAlbumId, 0), isNotNull);

      api.cipher = c2.cipher;
      live.ensureCover(_realAlbumId, [c2.preview]);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      await live.forget(_realAlbumId);
      expect(await heldInRam(real), isFalse,
          reason: 'the cover it showed an hour ago is still decrypted in RAM');
    });

    test('a decrypt that lands after the preview rolled is not kept', () async {
      final c2 = await _realCover();
      api.gate = Completer<void>();
      live.ensureCover(_realAlbumId, [real]);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      live.ensureCover(_realAlbumId, [c2.preview]);

      api.gate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(await l2.readRecord(real.mediaId), isNotNull,
          reason: 'A must really have decrypted, or this proves nothing');

      await live.forget(_realAlbumId);
      expect(await heldInRam(real), isFalse,
          reason: 'a load finishing after the roll put A back where forget '
              'could not reach it');
    });

    test('suspend drops plaintext the album no longer shows', () async {
      final c2 = await _realCover();
      live.ensureCover(_realAlbumId, [real]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      api.cipher = c2.cipher;
      live.ensureCover(_realAlbumId, [c2.preview]);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      live.suspend();
      expect(await heldInRam(real), isFalse);
      expect(await heldInRam(c2.preview), isFalse);
    });
  });

  test('suspend drops plaintext but keeps the registry for resume', () async {
    covers.ensureCover('a1', [_preview('m1')]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final first = api.urlCalls;
    expect(first, 1);

    covers.suspend();
    expect(covers.bytes('a1', 0), isNull);

    covers.resume();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(api.urlCalls, greaterThan(first),
        reason: 'clearing the registry would leave resume nothing to reload');
  });

  test('resume asks again for a cover that failed', () async {
    covers.ensureCover('a1', [_preview('m1')]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final first = api.urlCalls;

    covers.resume();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(api.urlCalls, first + 1,
        reason: 'coming back to the foreground is a real second chance');
  });

  test('rapid preview updates leave the newest registry last', () async {
    covers.ensureCover('a1', [_preview('m1'), _preview('m2')]);
    covers.ensureCover('a1', [_preview('m3')]);
    covers.ensureCover('a1', [_preview('m4'), _preview('m5')]);
    await covers.forget('a1');

    expect(await l2.coversFor('a1'), ['m4', 'm5'],
        reason: 'unchained writes can land out of order and pin stale covers');
  });

  test('a registry write cannot outlive the album it belongs to', () async {
    covers.ensureCover('a1', [_preview('m1'), _preview('m2')]);
    await covers.forget('a1');
    await l2.clearAlbum('a1');

    expect(await l2.coversFor('a1'), isEmpty,
        reason: 'a pending write would reinsert rows for a removed album');
  });
}
