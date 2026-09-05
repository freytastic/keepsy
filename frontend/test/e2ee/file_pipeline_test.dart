import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:keepsy/crypto/aead_stream.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/diagnostics/trace.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';

import '../secure_store/mock_secure_key_store.dart';

Uint8List _albumId([int seed = 0xA1]) =>
    Uint8List.fromList(List<int>.filled(16, seed));

Uint8List _mk([int seed = 0x42]) =>
    Uint8List.fromList(List<int>.filled(32, seed));

Uint8List _bytes(int n, [int seed = 0]) {
  final out = Uint8List(n);
  var x = seed;
  for (var i = 0; i < n; i++) {
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF;
    out[i] = x & 0xFF;
  }
  return out;
}

// A real JPEG that carries EXIF. package:image does not round trip a
// self authored GPS sub IFD, so we tag Make/Model : the strip asserts the WHOLE
// exif container is empty afterward, which subsumes GPS (itself a gps sub-IFD)
Uint8List _jpegWithExif() {
  final src = img.Image(width: 16, height: 16);
  img.fill(src, color: img.ColorRgb8(120, 200, 40));
  src.exif.imageIfd['Make'] = 'EvilCam';
  src.exif.imageIfd['Model'] = 'GPS-9000';
  return Uint8List.fromList(img.encodeJpg(src, quality: 95));
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

// _decryptEnvelope mirrors what §5.2 download will eventually do : unwrap the
// DEK using MK, then decrypt cipherBytes with DEK. Lets the §5.1 tests prove
// round trip without relying on §5.2 code that doesnt exist yet
Future<Uint8List> _decryptEnvelope({
  required AlbumKeyStore aks,
  required Uint8List albumId,
  required UploadEnvelope env,
}) async {
  final wrapAad = Uint8List(20);
  wrapAad.setRange(0, 16, albumId);
  ByteData.sublistView(wrapAad, 16).setUint32(0, env.epoch, Endian.big);
  // Reassemble VER ‖ NONCE ‖ TAG_CT
  final wrapWire = Uint8List(1 + env.wrapNonce.length + env.wrapTagCT.length);
  wrapWire[0] = kVerAesGcm;
  wrapWire.setRange(1, 1 + env.wrapNonce.length, env.wrapNonce);
  wrapWire.setRange(1 + env.wrapNonce.length, wrapWire.length, env.wrapTagCT);

  final dek = await aks.useMk<Uint8List>(albumId, env.epoch, (mk) async {
    return Aead.decrypt(wire: wrapWire, key: mk, aad: wrapAad);
  });

  final ver = env.cipherBytes[0];
  if (ver == kVerStreamGcm) {
    return AeadStream.decryptBytes(
        dek: dek, wire: env.cipherBytes, mediaId: env.mediaId);
  }
  return Aead.decrypt(wire: env.cipherBytes, key: dek, aad: env.mediaId);
}

void main() {
  // The size/wrap/round-trip machinery is media-type-agnostic : it is exercised
  // with mediaType 'video' since videos encrypt arbitrary bytes raw (no decode)
  // Photos now REQUIRE a decodable image (they are stripped + fail closed), so
  // random bytes cannot stand in for a photo any more
  group('FilePipeline.prepareUpload (encryption machinery)', () {
    test('round trip small file uses VER=0x01', () async {
      final aks = await _newAks(_albumId(), 3, _mk());
      final pt = _bytes(100 * 1024); // 100 KB : well under 1 MiB
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumId(),
        currentEpoch: 3,
        plaintext: pt,
        mediaType: 'video',
        mimeType: 'video/mp4',
      );
      expect(env.cipherBytes[0], kVerAesGcm);
      expect(env.epoch, 3);
      expect(env.mediaType, 'video');
      expect(env.mimeType, 'video/mp4');
      expect(env.wrapNonce.length, 12);
      expect(env.wrapTagCT.length, 48);
      expect(env.blobSize, env.cipherBytes.length);
      expect(env.blobSha256.length, 32);
      expect(env.mediaId.length, 16);

      final got =
          await _decryptEnvelope(aks: aks, albumId: _albumId(), env: env);
      expect(got, equals(pt));
    });

    test('round trip large file uses VER=0x03', () async {
      final aks = await _newAks(_albumId(), 3, _mk());
      final pt = _bytes(2 * kSegmentSize + 100); // 3 segments
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumId(),
        currentEpoch: 3,
        plaintext: pt,
        mediaType: 'video',
      );
      expect(env.cipherBytes[0], kVerStreamGcm);
      final got =
          await _decryptEnvelope(aks: aks, albumId: _albumId(), env: env);
      expect(got, equals(pt));
    });

    test('boundary : 1 MiB-1 stays VER=0x01, 1 MiB flips to VER=0x03',
        () async {
      final aks = await _newAks(_albumId(), 0, _mk());
      final justUnder = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumId(),
        currentEpoch: 0,
        plaintext: _bytes(kSegmentSize - 1),
        mediaType: 'video',
      );
      final atThreshold = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumId(),
        currentEpoch: 0,
        plaintext: _bytes(kSegmentSize),
        mediaType: 'video',
      );
      expect(justUnder.cipherBytes[0], kVerAesGcm);
      expect(atThreshold.cipherBytes[0], kVerStreamGcm);
    });

    test('blob_sha256 is the SHA256 of cipherBytes', () async {
      final aks = await _newAks(_albumId(), 0, _mk());
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumId(),
        currentEpoch: 0,
        plaintext: _bytes(50 * 1024),
        mediaType: 'video',
      );
      final h = await cg.Sha256().hash(env.cipherBytes);
      expect(env.blobSha256, equals(Uint8List.fromList(h.bytes)));
    });

    test('different albums on the same plaintext produce different wraps',
        () async {
      final aksA = await _newAks(_albumId(0xA1), 0, _mk(0x11));
      final aksB = await _newAks(_albumId(0xB2), 0, _mk(0x22));
      final pt = _bytes(50 * 1024);
      final envA = await FilePipeline.prepareUpload(
        aks: aksA,
        albumIdBytes: _albumId(0xA1),
        currentEpoch: 0,
        plaintext: pt,
        mediaType: 'video',
      );
      final envB = await FilePipeline.prepareUpload(
        aks: aksB,
        albumIdBytes: _albumId(0xB2),
        currentEpoch: 0,
        plaintext: pt,
        mediaType: 'video',
      );
      expect(envA.wrapTagCT, isNot(equals(envB.wrapTagCT)),
          reason: 'wrap is keyed on MK + AAD ; different albums must diverge');
    });

    test('rejects bad albumIdBytes length', () async {
      final aks = await _newAks(_albumId(), 0, _mk());
      await expectLater(
        FilePipeline.prepareUpload(
          aks: aks,
          albumIdBytes: Uint8List(15), // bad
          currentEpoch: 0,
          plaintext: _bytes(100),
          mediaType: 'video',
        ),
        throwsArgumentError,
      );
    });

    test('rejects bad mediaType', () async {
      final aks = await _newAks(_albumId(), 0, _mk());
      await expectLater(
        FilePipeline.prepareUpload(
          aks: aks,
          albumIdBytes: _albumId(),
          currentEpoch: 0,
          plaintext: _bytes(100),
          mediaType: 'audio',
        ),
        throwsArgumentError,
      );
    });
  });

  group('FilePipeline.prepareUpload photo metadata stripping', () {
    test('emits correlated timings for every CPU-heavy photo stage', () async {
      final aks = await _newAks(_albumId(), 0, _mk());
      final lines = <String>[];
      Trace.debugEnabled = true;
      try {
        await runZoned(
          () => Trace.withId(
            'uploadtrace',
            () => FilePipeline.prepareUpload(
              aks: aks,
              albumIdBytes: _albumId(),
              currentEpoch: 0,
              plaintext: _jpegWithExif(),
              mediaType: 'photo',
            ),
          ),
          zoneSpecification: ZoneSpecification(
            print: (_, __, ___, line) => lines.add(line),
          ),
        );
      } finally {
        Trace.debugEnabled = null;
      }

      for (final name in [
        'media.prepareUpload',
        'media.imageDecode',
        'media.imageEncode',
        'media.thumbResize',
        'media.thumbEncode',
        'media.fileEncrypt',
        'media.keyWrap',
      ]) {
        expect(lines.any((line) => line.contains('$name.start')), isTrue,
            reason: '$name must have a start marker');
        expect(lines.any((line) => line.contains('$name.end')), isTrue,
            reason: '$name must have an end marker');
      }
      expect(lines, everyElement(contains('tid=uploadtrace')));
    });

    test('uploaded photo bytes carry no EXIF/GPS, thumb included', () async {
      final withExif = _jpegWithExif();
      // precondition : the fixture really does carry EXIF
      expect(img.decodeImage(withExif)!.exif.isEmpty, isFalse,
          reason:
              'fixture must start WITH metadata for the test to mean anything');

      final aks = await _newAks(_albumId(), 0, _mk());
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumId(),
        currentEpoch: 0,
        plaintext: withExif,
        mediaType: 'photo',
        mimeType: 'image/jpeg',
      );

      // decrypt what would actually be uploaded and confirm it is metadata free
      final clean =
          await _decryptEnvelope(aks: aks, albumId: _albumId(), env: env);
      expect(img.decodeImage(clean)!.exif.isEmpty, isTrue,
          reason: 'uploaded photo must carry no EXIF');
      // the thumbnail is derived from the same decode : it must be clean too
      expect(env.thumbPlaintext, isNotNull);
      expect(img.decodeImage(env.thumbPlaintext!)!.exif.isEmpty, isTrue,
          reason: 'thumbnail must carry no EXIF');
    });

    test('output photo keeps correct orientation (portrait stays upright)',
        () async {
      // 16x8 landscape pixels tagged orientation=6 (rotate 90 CW) : a real
      // portrait camera photo. img.decodeImage auto applies the orientation
      // (rotates pixels to 8x16, clears the tag) BEFORE we clear the rest of
      // the EXIF, so stripping can never leave the photo sideways. This test
      // guards that end to end : if a future package:image stops auto-orienting
      // it goes red, and an explicit bakeOrientation would be needed
      final src = img.Image(width: 16, height: 8);
      img.fill(src, color: img.ColorRgb8(10, 20, 30));
      src.exif.imageIfd.orientation = 6;
      final oriented = Uint8List.fromList(img.encodeJpg(src, quality: 95));

      final aks = await _newAks(_albumId(), 0, _mk());
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumId(),
        currentEpoch: 0,
        plaintext: oriented,
        mediaType: 'photo',
      );
      final clean =
          await _decryptEnvelope(aks: aks, albumId: _albumId(), env: env);
      final out = img.decodeImage(clean)!;
      expect(out.width, 8, reason: 'orientation must be baked into the pixels');
      expect(out.height, 16);
      expect(out.exif.isEmpty, isTrue);
    });

    test('an accepted photo is always reported as image/jpeg', () async {
      // we re encode every photo to JPEG, so a decoded PNG/WebP must not keep
      // its old mime : the stored bytes are JPEG
      final aks = await _newAks(_albumId(), 0, _mk());
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumId(),
        currentEpoch: 0,
        plaintext: _jpegWithExif(),
        mediaType: 'photo',
        mimeType: 'image/png',
      );
      expect(env.mimeType, 'image/jpeg');
    });

    test('fails closed on a photo that cannot be decoded (never uploads raw)',
        () async {
      final aks = await _newAks(_albumId(), 0, _mk());
      await expectLater(
        FilePipeline.prepareUpload(
          aks: aks,
          albumIdBytes: _albumId(),
          currentEpoch: 0,
          plaintext: _bytes(4096), // not a decodable image
          mediaType: 'photo',
        ),
        throwsA(isA<UnprocessableImageException>()),
      );
    });
  });
}
