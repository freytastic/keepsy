import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';

import '../secure_store/mock_secure_key_store.dart';

final _album = Uint8List.fromList(List<int>.filled(16, 0xA1));
Uint8List _mk(int seed) => Uint8List.fromList(List<int>.filled(32, seed));

Uint8List _aad(int epoch) {
  final out = Uint8List(20)..setRange(0, 16, _album);
  ByteData.sublistView(out, 16).setUint32(0, epoch, Endian.big);
  return out;
}

Future<AlbumKeyStore> _aks(Map<int, Uint8List> mks) async {
  final s = MockSecureKeyStore();
  await s.initialize();
  final aks = AlbumKeyStore(s);
  await aks.initialize();
  for (final e in mks.entries) {
    await aks.install(_album, e.key, e.value);
  }
  return aks;
}

Future<Uint8List> _unwrap(UploadEnvelope env, Uint8List mk) => Aead.decrypt(
      wire:
          Uint8List.fromList([kVerAesGcm, ...env.wrapNonce, ...env.wrapTagCT]),
      key: mk,
      aad: _aad(env.epoch),
    );

void main() {
  test('the ciphertext does not depend on the album key it is wrapped under',
      () async {
    final media = await FilePipeline.encryptMedia(
        plaintext: Uint8List.fromList(List<int>.generate(4096, (i) => i)),
        mediaType: 'video');
    final aks = await _aks({0: _mk(1), 1: _mk(2)});

    final a = await FilePipeline.wrapKeys(
        aks: aks, albumIdBytes: _album, epoch: 0, media: media);
    final b = await FilePipeline.wrapKeys(
        aks: aks, albumIdBytes: _album, epoch: 1, media: media);

    expect(a.cipherBytes, b.cipherBytes);
    expect(a.blobSha256, b.blobSha256);
    expect(await _unwrap(a, _mk(1)), media.dek);
    expect(await _unwrap(b, _mk(2)), media.dek);
    await expectLater(_unwrap(a, _mk(2)), throwsA(isA<AeadAuthFailed>()),
        reason: 'each wrap opens only under its own epoch key');
  });

  test('a sealed thumbnail opens without any album key', () async {
    final src = img.Image(width: 20, height: 12);
    img.fill(src, color: img.ColorRgb8(10, 120, 200));
    final media = await FilePipeline.encryptMedia(
        plaintext: Uint8List.fromList(img.encodeJpg(src)), mediaType: 'photo');

    expect(await FilePipeline.openThumb(media), media.thumbPlaintext);
  });

  test('zeroKeys wipes both DEKs', () async {
    final src = img.Image(width: 8, height: 8);
    final media = await FilePipeline.encryptMedia(
        plaintext: Uint8List.fromList(img.encodeJpg(src)), mediaType: 'photo');

    media.zeroKeys();
    expect(media.dek, everyElement(0));
    expect(media.thumbDek, everyElement(0));
  });

  test('a video has no thumbnail to wrap', () async {
    final media = await FilePipeline.encryptMedia(
        plaintext: Uint8List(64), mediaType: 'video');
    final env = await FilePipeline.wrapKeys(
        aks: await _aks({0: _mk(1)}),
        albumIdBytes: _album,
        epoch: 0,
        media: media);

    expect(env.hasThumb, isFalse);
    expect(env.thumbWrapNonce, isNull);
    expect(await FilePipeline.openThumb(media), isNull);
  });
}
