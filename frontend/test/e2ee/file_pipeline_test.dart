import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/crypto/aead_stream.dart';
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
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
  group('FilePipeline.prepareUpload', () {
    test('round trip small file uses VER=0x01', () async {
      final aks = await _newAks(_albumId(), 3, _mk());
      final pt = _bytes(100 * 1024); // 100 KB : well under 1 MiB
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumId(),
        currentEpoch: 3,
        plaintext: pt,
        mediaType: 'photo',
        mimeType: 'image/jpeg',
      );
      expect(env.cipherBytes[0], kVerAesGcm);
      expect(env.epoch, 3);
      expect(env.mediaType, 'photo');
      expect(env.mimeType, 'image/jpeg');
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
        mediaType: 'photo',
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
        mediaType: 'photo',
      );
      final atThreshold = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumId(),
        currentEpoch: 0,
        plaintext: _bytes(kSegmentSize),
        mediaType: 'photo',
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
        mediaType: 'photo',
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
        mediaType: 'photo',
      );
      final envB = await FilePipeline.prepareUpload(
        aks: aksB,
        albumIdBytes: _albumId(0xB2),
        currentEpoch: 0,
        plaintext: pt,
        mediaType: 'photo',
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
          mediaType: 'photo',
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
}
