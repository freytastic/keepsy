import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/file_decryptor.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';
import 'package:keepsy/e2ee/media_record.dart';

import '../secure_store/mock_secure_key_store.dart';

// thumbnail coverage. The EXIF strip itself is asserted in file_pipeline_test
// (an EXIF bearing JPEG comes out metadata free). Tests below cover the
// byte level surface we own : thumb cipher shape, dual wrap with shared
// wrap_aad, thumb-AAD distinct from file-AAD, video yields no thumb, and an
// undecodable photo fails closed

Uint8List _albumId([int seed = 0xA1]) =>
    Uint8List.fromList(List<int>.filled(16, seed));

Uint8List _mk([int seed = 0x42]) =>
    Uint8List.fromList(List<int>.filled(32, seed));

// _syntheticJpegBytes : 200x150 solid-color JPEG. Decodes cleanly so
// FilePipeline.prepareUpload exercises the EXIF-strip + thumb-gen path
Uint8List _syntheticJpegBytes({int w = 200, int h = 150}) {
  final image = img.Image(width: w, height: h);
  for (final p in image) {
    p.setRgb(120, 200, 80);
  }
  return img.encodeJpg(image, quality: 90);
}

Future<AlbumKeyStore> _newAks(
    Uint8List albumId, int epoch, Uint8List mk) async {
  final s = MockSecureKeyStore();
  await s.initialize();
  final aks = AlbumKeyStore(s);
  await aks.initialize();
  await aks.installVerified(
      albumId: albumId, epoch: epoch, mk: mk, backfill: false);
  return aks;
}

// Test seam mirroring MediaApi.downloadCiphertext : returns the in-memory
// thumb bytes regardless of URL (no real S3 in unit tests)
DownloadFn _staticDownload(Uint8List bytes) => (String _) async => bytes;

// _recordFromEnvelope : builds a MediaRecord matching the envelope so
// FileDecryptor sees the same wrap nonces + tag-cts + size + sha as the
// uploader would have published via ListMedia
MediaRecord _recordFromEnvelope({
  required UploadEnvelope env,
  required Uint8List albumIdBytes,
}) {
  final albumIdStr = _uuidStringFromBytes(albumIdBytes);
  final mediaIdStr = env.mediaIdString;
  return MediaRecord(
    id: mediaIdStr,
    albumId: albumIdStr,
    uploaderToken: '',
    wrapNonce: env.wrapNonce,
    wrapTagCT: env.wrapTagCT,
    epochTag: env.epoch,
    blobSize: env.blobSize,
    blobSha256: env.blobSha256,
    mediaType: env.mediaType,
    mimeType: env.mimeType,
    createdAt: DateTime.now(),
    thumbWrapNonce: env.thumbWrapNonce,
    thumbWrapTagCT: env.thumbWrapTagCT,
    thumbSize: env.thumbSize == 0 ? null : env.thumbSize,
    thumbSha256: env.thumbSha256,
  );
}

String _uuidStringFromBytes(Uint8List b) {
  final s = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
      '-${s.substring(16, 20)}-${s.substring(20)}';
}

void main() {
  group('FilePipeline thumb generation', () {
    test('photo plaintext yields thumb cipher + 48B wrap_tag_ct + 12B nonce',
        () async {
      final aks = await _newAks(_albumId(), 0, _mk());
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumId(),
        currentEpoch: 0,
        plaintext: _syntheticJpegBytes(),
        mediaType: 'photo',
      );
      expect(env.hasThumb, isTrue);
      expect(env.thumbCipherBytes, isNotNull);
      expect(env.thumbWrapNonce!.length, 12);
      expect(env.thumbWrapTagCT!.length, 48);
      expect(env.thumbSha256!.length, 32);
      // 200x150 jpeg @ q=70 should be well under the 500KB server cap +
      // well above the 17B AEAD overhead minimum
      expect(env.thumbSize, greaterThan(100));
      expect(env.thumbSize, lessThan(50 * 1024));
    });

    test('video plaintext yields NO thumb (server skips thumb pipeline)',
        () async {
      final aks = await _newAks(_albumId(), 0, _mk());
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumId(),
        currentEpoch: 0,
        plaintext: _syntheticJpegBytes(),
        mediaType: 'video',
      );
      expect(env.hasThumb, isFalse);
      expect(env.thumbCipherBytes, isNull);
      expect(env.thumbWrapNonce, isNull);
      expect(env.thumbWrapTagCT, isNull);
      expect(env.thumbSha256, isNull);
    });

    test('undecodable photo fails closed (never uploads unstripped bytes)',
        () async {
      final aks = await _newAks(_albumId(), 0, _mk());
      // Random bytes : not a decodable image. A photo we cant decode cant have
      // its metadata stripped, so prepareUpload refuses rather than upload it
      final junk =
          Uint8List.fromList(List<int>.generate(2048, (i) => i & 0xFF));
      await expectLater(
        FilePipeline.prepareUpload(
          aks: aks,
          albumIdBytes: _albumId(),
          currentEpoch: 0,
          plaintext: junk,
          mediaType: 'photo',
        ),
        throwsA(isA<UnprocessableImageException>()),
      );
    });

    test('two photos with same plaintext + same MK yield distinct thumb DEKs',
        () async {
      // dek_thumb is freshly random each upload → wrap_tag_ct must differ
      final aks = await _newAks(_albumId(), 0, _mk());
      final pt = _syntheticJpegBytes();
      final a = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumId(),
        currentEpoch: 0,
        plaintext: pt,
        mediaType: 'photo',
      );
      final b = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumId(),
        currentEpoch: 0,
        plaintext: pt,
        mediaType: 'photo',
      );
      expect(a.thumbWrapTagCT, isNot(equals(b.thumbWrapTagCT)),
          reason: 'fresh dek_thumb per upload → distinct wrap_tag_ct');
      expect(a.thumbCipherBytes, isNot(equals(b.thumbCipherBytes)),
          reason: 'distinct dek_thumb + fresh AES-GCM nonce → distinct cipher');
    });
  });

  group('FileDecryptor.downloadAndDecryptThumb', () {
    test('thumb round-trip : encrypt → decrypt yields a decodable JPEG',
        () async {
      final aks = await _newAks(_albumId(), 0, _mk());
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumId(),
        currentEpoch: 0,
        plaintext: _syntheticJpegBytes(),
        mediaType: 'photo',
      );
      final record = _recordFromEnvelope(env: env, albumIdBytes: _albumId());
      final pt = await FileDecryptor.downloadAndDecryptThumb(
        aks: aks,
        record: record,
        presignedUrl: 'http://test/thumb',
        download: _staticDownload(env.thumbCipherBytes!),
      );
      // Decrypted thumb should be a valid JPEG (image.decode returns non-null)
      final decoded = img.decodeImage(pt);
      expect(decoded, isNotNull);
      // 400px long-edge resize : longer dimension should be ~400
      expect(decoded!.width == 400 || decoded.height == 400, isTrue,
          reason:
              'thumb resized to 400px long edge ; got ${decoded.width}x${decoded.height}');
    });

    test('no_thumb error when record has no thumb fields', () async {
      final aks = await _newAks(_albumId(), 0, _mk());
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumId(),
        currentEpoch: 0,
        plaintext: _syntheticJpegBytes(),
        mediaType: 'video', // skips thumb pipeline
      );
      final record = _recordFromEnvelope(env: env, albumIdBytes: _albumId());
      expect(record.hasThumb, isFalse);
      await expectLater(
        FileDecryptor.downloadAndDecryptThumb(
          aks: aks,
          record: record,
          presignedUrl: 'http://test/x',
          download: _staticDownload(Uint8List(0)),
        ),
        throwsA(
            predicate((e) => e is FileDecryptError && e.reason == 'no_thumb')),
      );
    });

    test('SHA256 mismatch on cipher → sha256_mismatch error', () async {
      final aks = await _newAks(_albumId(), 0, _mk());
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumId(),
        currentEpoch: 0,
        plaintext: _syntheticJpegBytes(),
        mediaType: 'photo',
      );
      final record = _recordFromEnvelope(env: env, albumIdBytes: _albumId());
      // Flip one byte in the thumb cipher : sha256 won't match expected
      final tampered = Uint8List.fromList(env.thumbCipherBytes!);
      tampered[tampered.length - 1] ^= 0xFF;
      await expectLater(
        FileDecryptor.downloadAndDecryptThumb(
          aks: aks,
          record: record,
          presignedUrl: 'http://test/thumb',
          download: _staticDownload(tampered),
        ),
        throwsA(predicate(
            (e) => e is FileDecryptError && e.reason == 'sha256_mismatch')),
      );
    });

    test('AAD binding : thumb cipher refuses file-style AAD (media_id alone)',
        () async {
      // Decrypt path uses media_id ‖ "thumb" as AAD. Prove that decrypting
      // with the FILE AAD (media_id alone, no suffix) fails the AEAD tag
      final aks = await _newAks(_albumId(), 0, _mk());
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumId(),
        currentEpoch: 0,
        plaintext: _syntheticJpegBytes(),
        mediaType: 'photo',
      );
      // Unwrap dek_thumb manually so we can attempt direct AEAD calls
      final wrapWire = Uint8List(1 + 12 + 48);
      wrapWire[0] = kVerAesGcm;
      wrapWire.setRange(1, 13, env.thumbWrapNonce!);
      wrapWire.setRange(13, 61, env.thumbWrapTagCT!);
      final wrapAad = Uint8List(20);
      wrapAad.setRange(0, 16, _albumId());
      ByteData.sublistView(wrapAad, 16).setUint32(0, env.epoch, Endian.big);
      final dekThumb = await aks.useMk<Uint8List>(_albumId(), env.epoch,
          (mk) async => Aead.decrypt(wire: wrapWire, key: mk, aad: wrapAad));

      // Wrong AAD (file-style : media_id alone) → AeadAuthFailed
      await expectLater(
        Aead.decrypt(
            wire: env.thumbCipherBytes!, key: dekThumb, aad: env.mediaId),
        throwsA(isA<AeadAuthFailed>()),
      );
      // Correct AAD (media_id ‖ "thumb") → succeeds
      final correctAad =
          Uint8List(env.mediaId.length + 'thumb'.codeUnits.length);
      correctAad.setRange(0, env.mediaId.length, env.mediaId);
      correctAad.setRange(
          env.mediaId.length, correctAad.length, 'thumb'.codeUnits);
      final pt = await Aead.decrypt(
          wire: env.thumbCipherBytes!, key: dekThumb, aad: correctAad);
      expect(pt, isNotEmpty);
    });
  });
}
