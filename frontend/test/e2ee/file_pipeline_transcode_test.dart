import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:keepsy/e2ee/file_pipeline.dart';
import 'package:keepsy/e2ee/jpeg_sanity.dart';

Uint8List _jpeg({int width = 12, int height = 6, int quality = 90}) {
  final src = img.Image(width: width, height: height);
  img.fill(src, color: img.ColorRgb8(90, 40, 10));
  return Uint8List.fromList(img.encodeJpg(src, quality: quality));
}

Uint8List _jpegWithExif() {
  final src = img.Image(width: 12, height: 6);
  img.fill(src, color: img.ColorRgb8(90, 40, 10));
  src.exif.imageIfd['Make'] = 'keepsy';
  return Uint8List.fromList(img.encodeJpg(src, quality: 90));
}

Uint8List _unreadable() => Uint8List.fromList(List<int>.filled(4096, 0x2A));

TranscodedPhoto _photo({Uint8List? jpeg, Uint8List? thumb}) => TranscodedPhoto(
      jpeg: jpeg ?? _jpeg(),
      thumb: thumb ?? _jpeg(width: 6, height: 3),
      width: 12,
      height: 6,
    );

void _segment(BytesBuilder b, int marker, List<int> payload) {
  b.add([0xFF, marker, (payload.length + 2) >> 8, (payload.length + 2) & 0xFF]);
  b.add(payload);
}

// Two scans include a stuffed byte and restart marker
Uint8List _multiScan({bool hideComment = false}) {
  final b = BytesBuilder();
  b.add([0xFF, 0xD8]);
  _segment(b, 0xC2, List<int>.filled(9, 0));
  _segment(b, 0xC4, [0, 0]);
  _segment(b, 0xDA, [1, 0]);
  b.add([0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56]);
  if (hideComment) _segment(b, 0xFE, [0x68, 0x69]);
  _segment(b, 0xDA, [1, 0]);
  b.add([0x78, 0xFF, 0x00, 0x9A]);
  b.add([0xFF, 0xD9]);
  return b.toBytes();
}

void main() {
  group('photo routing', () {
    test('the platform runs first, even on a decodable JPEG', () async {
      var calls = 0;
      final media = await FilePipeline.encryptMedia(
        plaintext: _jpeg(),
        mediaType: 'photo',
        transcode: (bytes) async {
          calls++;
          return TranscodeDone(_photo());
        },
      );
      expect(calls, 1, reason: 'package:image must not be the default path');
      expect(media.thumbCipherBytes, isNotNull);
    });

    test('platform output is carried through without a second encode',
        () async {
      final out = _photo();
      final media = await FilePipeline.encryptMedia(
        plaintext: _unreadable(),
        mediaType: 'photo',
        transcode: (bytes) async => TranscodeDone(out),
      );
      expect(media.mimeType, 'image/jpeg');
      expect(media.filePlaintext, orderedEquals(out.jpeg),
          reason: 'nothing to strip, so the bytes survive unchanged');
      expect(media.thumbPlaintext, orderedEquals(out.thumb));
    });

    test('metadata the encoder attached is stripped, not uploaded', () async {
      final media = await FilePipeline.encryptMedia(
        plaintext: _unreadable(),
        mediaType: 'photo',
        transcode: (bytes) async =>
            TranscodeDone(_photo(jpeg: _jpegWithExif())),
      );
      final out = media.filePlaintext!;
      expect(JpegSanity.isClean(out), isTrue);
      expect(img.decodeImage(out)!.exif.isEmpty, isTrue);
      expect(img.decodeImage(out)!.width, 12,
          reason: 'stripping must not disturb the picture');
    });

    // Rejected images must never reach the uncapped Dart decoder
    test('a platform refusal never falls back to Dart', () async {
      await expectLater(
        FilePipeline.encryptMedia(
          plaintext: _jpeg(),
          mediaType: 'photo',
          transcode: (bytes) async => const TranscodeRejected('out of memory'),
        ),
        throwsA(isA<UnprocessableImageException>()),
      );
    });

    test('an unavailable platform falls back to Dart', () async {
      final media = await FilePipeline.encryptMedia(
        plaintext: _jpeg(),
        mediaType: 'photo',
        transcode: (bytes) async => const TranscodeUnavailable(),
      );
      expect(media.thumbCipherBytes, isNotNull);
      expect(img.decodeImage(media.filePlaintext!)!.exif.isEmpty, isTrue);
    });

    test('unavailable on bytes Dart cannot read either stays fail closed',
        () async {
      await expectLater(
        FilePipeline.encryptMedia(
          plaintext: _unreadable(),
          mediaType: 'photo',
          transcode: (bytes) async => const TranscodeUnavailable(),
        ),
        throwsA(isA<UnprocessableImageException>()),
      );
    });

    test('a structurally broken transcode stays fail closed', () async {
      final broken = _jpeg();
      await expectLater(
        FilePipeline.encryptMedia(
          plaintext: _unreadable(),
          mediaType: 'photo',
          transcode: (bytes) async => TranscodeDone(
              _photo(jpeg: broken.sublist(0, broken.length - 4))),
        ),
        throwsA(isA<UnprocessableImageException>()),
      );
    });
  });

  group('JpegSanity', () {
    test('accepts a bare encode', () {
      expect(JpegSanity.isClean(_jpeg()), isTrue);
    });

    // Build this path by hand because package:image emits baseline JPEG
    test('walks every scan of a multi scan stream', () {
      expect(JpegSanity.isClean(_multiScan()), isTrue);
    });

    test('finds a comment hidden after the first scan', () {
      expect(JpegSanity.isClean(_multiScan(hideComment: true)), isFalse);
    });

    test('rejects EXIF', () {
      expect(JpegSanity.isClean(_jpegWithExif()), isFalse);
    });

    test('rejects a payload appended after the end marker', () {
      final b = BytesBuilder()
        ..add(_jpeg())
        ..add(Uint8List.fromList([1, 2, 3, 4]));
      expect(JpegSanity.isClean(b.toBytes()), isFalse);
    });

    test('rejects truncation and non JPEG input', () {
      final full = _jpeg();
      expect(JpegSanity.isClean(full.sublist(0, full.length - 4)), isFalse);
      expect(JpegSanity.isClean(_unreadable()), isFalse);
      expect(JpegSanity.isClean(Uint8List(0)), isFalse);
    });
  });
}
