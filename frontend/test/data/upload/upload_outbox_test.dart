import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:keepsy/crypto/aead_stream.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/data/upload/upload_adapters.dart';
import 'package:keepsy/data/upload/upload_outbox.dart';
import 'package:keepsy/domain/upload/upload_item.dart';
import 'package:keepsy/domain/upload/upload_ports.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';

import '../../secure_store/mock_secure_key_store.dart';

const _album = 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1';
final _albumBytes = Uint8List.fromList(List<int>.filled(16, 0xA1));
final _rootKey = Uint8List.fromList(List<int>.filled(32, 0x33));

Uint8List _jpeg() {
  final src = img.Image(width: 24, height: 16);
  img.fill(src, color: img.ColorRgb8(200, 80, 40));
  return Uint8List.fromList(img.encodeJpg(src, quality: 90));
}

Future<AlbumKeyStore> _aks({Uint8List? mk}) async {
  final s = MockSecureKeyStore();
  await s.initialize();
  final aks = AlbumKeyStore(s);
  await aks.initialize();
  if (mk != null) await aks.install(_albumBytes, 4, mk);
  return aks;
}

Uint8List _wrapAad(int epoch) {
  final out = Uint8List(20)..setRange(0, 16, _albumBytes);
  ByteData.sublistView(out, 16).setUint32(0, epoch, Endian.big);
  return out;
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('keepsy_outbox_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<UploadOutboxStore> openStore() =>
      UploadOutboxStore.open(dir: dir, cacheRootKey: _rootKey);

  Future<EncryptedMedia> encrypt() =>
      FilePipeline.encryptMedia(plaintext: _jpeg(), mediaType: 'photo');

  group('UploadOutboxStore', () {
    test('holdsAlbum sees what clearAlbum left behind', () async {
      final store = await openStore();
      await store.put(
          itemId: 'item-1',
          albumId: _album,
          owner: 'u1',
          media: await encrypt());
      expect(await store.holdsAlbum(_album), isTrue);
      expect(await store.holdsAlbum('other-album'), isFalse);

      await store.clearAlbum(_album);
      expect(await store.holdsAlbum(_album), isFalse);
    });

    test('a sealed photo round trips with its keys intact', () async {
      final store = await openStore();
      final media = await encrypt();
      await store.put(
          itemId: 'item-1', albumId: _album, owner: 'u1', media: media);

      final back = (await store.load('item-1', owner: 'u1'))!;
      expect(back.cipherBytes, media.cipherBytes);
      expect(back.dek, media.dek);
      expect(back.thumbDek, media.thumbDek);
      expect(back.mediaId, media.mediaId);
      expect(back.filePlaintext, isNull,
          reason: 'plaintext never touches the disk');
    });

    test('the keys are not readable on disk', () async {
      final store = await openStore();
      final media = await encrypt();
      await store.put(
          itemId: 'item-1', albumId: _album, owner: 'u1', media: media);

      final meta = await File('${dir.path}/item-1.meta').readAsBytes();
      expect(_contains(meta, media.dek), isFalse);
      expect(meta.first, kVerAesGcm);
    });

    test('another account can neither load nor restore the photo', () async {
      final store = await openStore();
      await store.put(
          itemId: 'item-1',
          albumId: _album,
          owner: 'u1',
          media: await encrypt());

      expect(await store.load('item-1', owner: 'u2'), isNull);
      expect(await store.restore('u2'), isEmpty);
      expect(await store.restore('u1'), isEmpty,
          reason: 'restore by another login erases what it can never send');
    });

    test('restore lists entries oldest first with a decrypted preview',
        () async {
      final store = await openStore();
      final first = await encrypt();
      await store.put(itemId: 'a', albumId: _album, owner: 'u1', media: first);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.put(
          itemId: 'b', albumId: _album, owner: 'u1', media: await encrypt());

      final records = await store.restore('u1');
      expect(records.map((r) => r.itemId), ['a', 'b']);
      expect(records.first.thumbPreview, first.thumbPlaintext);
      expect(records.first.payloadByteLength, first.payloadByteLength);
    });

    test('a damaged blob is dropped instead of uploaded', () async {
      final store = await openStore();
      await store.put(
          itemId: 'item-1',
          albumId: _album,
          owner: 'u1',
          media: await encrypt());
      final blob = File('${dir.path}/item-1.file');
      final bytes = await blob.readAsBytes();
      bytes[bytes.length - 1] ^= 0xFF;
      await blob.writeAsBytes(bytes);

      expect(await store.load('item-1', owner: 'u1'), isNull,
          reason: 'the publish path refuses it, which retires the entry');
    });

    test('a meta whose blob is missing is erased at restore', () async {
      final store = await openStore();
      await store.put(
          itemId: 'item-1',
          albumId: _album,
          owner: 'u1',
          media: await encrypt());
      await File('${dir.path}/item-1.file').delete();

      expect(await store.restore('u1'), isEmpty);
      expect(await File('${dir.path}/item-1.meta').exists(), isFalse);
    });

    test('blobs whose meta never landed are swept at open', () async {
      await File('${dir.path}/orphan.file').writeAsBytes([1, 2, 3]);
      await File('${dir.path}/half.meta.tmp').writeAsBytes([1]);
      await openStore();

      expect(await dir.list().isEmpty, isTrue);
    });

    test('clearAlbum drops only that album', () async {
      final store = await openStore();
      await store.put(
          itemId: 'mine', albumId: _album, owner: 'u1', media: await encrypt());
      await store.put(
          itemId: 'other',
          albumId: 'b2b2b2b2-b2b2-b2b2-b2b2-b2b2b2b2b2b2',
          owner: 'u1',
          media: await encrypt());

      await store.clearAlbum(_album);
      expect((await store.restore('u1')).map((r) => r.itemId), ['other']);
    });

    test('clearAll leaves nothing behind', () async {
      final store = await openStore();
      await store.put(
          itemId: 'x', albumId: _album, owner: 'u1', media: await encrypt());
      await store.clearAll();
      expect(await dir.list().isEmpty, isTrue);
    });
  });

  group('MediaPreparerImpl', () {
    test('a sealed photo wraps into an envelope the album key opens', () async {
      final mk = Uint8List.fromList(List<int>.filled(32, 0x42));
      final prep = MediaPreparerImpl(await _aks(mk: mk), await openStore(),
          owner: () => 'u1');
      final mediaId = MediaId.fresh();
      final sealed = await prep.seal(
          itemId: 'item-1',
          albumId: _album,
          mediaId: mediaId,
          plaintext: _jpeg(),
          mimeType: 'image/png');
      final env = await prep.wrap(itemId: 'item-1', albumId: _album);

      expect(env.epoch, 4);
      expect(env.mimeType, 'image/jpeg');
      expect(sealed.payloadByteLength, env.blobSize + env.thumbSize);
      final dek = await Aead.decrypt(
        wire: Uint8List.fromList(
            [kVerAesGcm, ...env.wrapNonce, ...env.wrapTagCT]),
        key: mk,
        aad: _wrapAad(4),
      );
      final plain = env.cipherBytes.first == kVerStreamGcm
          ? await AeadStream.decryptBytes(
              dek: dek, wire: env.cipherBytes, mediaId: mediaId.bytes)
          : await Aead.decrypt(
              wire: env.cipherBytes, key: dek, aad: mediaId.bytes);
      expect(plain, env.filePlaintext,
          reason: 'the immediate publish keeps the plaintext for the cache');
    });

    test('a photo sealed before a restart wraps from disk', () async {
      final mk = Uint8List.fromList(List<int>.filled(32, 0x42));
      final store = await openStore();
      await MediaPreparerImpl(await _aks(mk: mk), store, owner: () => 'u1')
          .seal(
              itemId: 'item-1',
              albumId: _album,
              mediaId: MediaId.fresh(),
              plaintext: _jpeg(),
              mimeType: 'image/jpeg');

      final later = MediaPreparerImpl(await _aks(mk: mk), await openStore(),
          owner: () => 'u1');
      final restored = await later.restore();
      expect(restored.single.itemId, 'item-1');
      expect(restored.single.thumbPreview, isNotNull);

      final env = await later.wrap(itemId: 'item-1', albumId: _album);
      expect(env.filePlaintext, isNull);
      expect(env.hasThumb, isTrue);
    });

    test('a photo sealed by another login is never wrapped', () async {
      var owner = 'u1';
      final prep = MediaPreparerImpl(
          await _aks(mk: Uint8List(32)..fillRange(0, 32, 7)), await openStore(),
          owner: () => owner);
      await prep.seal(
          itemId: 'item-1',
          albumId: _album,
          mediaId: MediaId.fresh(),
          plaintext: _jpeg(),
          mimeType: 'image/jpeg');

      owner = 'u2';
      await expectLater(
        prep.wrap(itemId: 'item-1', albumId: _album),
        throwsA(isA<UploadStageException>()
            .having((e) => e.kind, 'kind', UploadFailureKind.sourceMissing)),
      );
    });

    test('sealing needs no album key but wrapping does', () async {
      final prep =
          MediaPreparerImpl(await _aks(), await openStore(), owner: () => 'u1');
      await prep.seal(
          itemId: 'item-1',
          albumId: _album,
          mediaId: MediaId.fresh(),
          plaintext: _jpeg(),
          mimeType: 'image/jpeg');

      await expectLater(
        prep.wrap(itemId: 'item-1', albumId: _album),
        throwsA(isA<UploadStageException>()
            .having((e) => e.kind, 'kind', UploadFailureKind.noAlbumKey)),
      );
    });

    test('sealing without a known account is refused', () async {
      final prep =
          MediaPreparerImpl(await _aks(), await openStore(), owner: () => null);
      await expectLater(
        prep.seal(
            itemId: 'item-1',
            albumId: _album,
            mediaId: MediaId.fresh(),
            plaintext: _jpeg(),
            mimeType: 'image/jpeg'),
        throwsA(isA<UploadStageException>()),
      );
      expect(await dir.list().isEmpty, isTrue);
    });

    test('an undecodable photo is refused before anything is stored', () async {
      final prep =
          MediaPreparerImpl(await _aks(), await openStore(), owner: () => 'u1');
      await expectLater(
        prep.seal(
            itemId: 'item-1',
            albumId: _album,
            mediaId: MediaId.fresh(),
            plaintext: Uint8List.fromList([1, 2, 3]),
            mimeType: 'image/jpeg'),
        throwsA(isA<UploadStageException>()
            .having((e) => e.kind, 'kind', UploadFailureKind.unprocessable)),
      );
      expect(await dir.list().isEmpty, isTrue);
    });

    test('discarding a sealed photo removes it for good', () async {
      final prep = MediaPreparerImpl(
          await _aks(mk: Uint8List(32)..fillRange(0, 32, 7)), await openStore(),
          owner: () => 'u1');
      await prep.seal(
          itemId: 'item-1',
          albumId: _album,
          mediaId: MediaId.fresh(),
          plaintext: _jpeg(),
          mimeType: 'image/jpeg');

      await prep.discardSealed('item-1');
      expect(await prep.restore(), isEmpty);
      await expectLater(prep.wrap(itemId: 'item-1', albumId: _album),
          throwsA(isA<UploadStageException>()));
    });
  });

  test('SealedUpload carries what the queue needs to show a restored photo',
      () {
    final s = SealedUpload(
        itemId: 'i',
        albumId: _album,
        mediaId: MediaId.fresh(),
        payloadByteLength: 10);
    expect(s.thumbPreview, isNull);
  });
}

bool _contains(Uint8List haystack, Uint8List needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
