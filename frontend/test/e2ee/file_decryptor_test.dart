import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/file_decryptor.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';

import '../secure_store/mock_secure_key_store.dart';

Uint8List _albumIdBytes([int seed = 0xA1]) =>
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

// _albumIdString : matches what the server would emit for the same 16 raw
// bytes. The decryptor decodes back to bytes via MediaRecord.albumIdBytes
String _albumIdString(Uint8List bytes) {
  final s = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
      '-${s.substring(16, 20)}-${s.substring(20)}';
}

String _mediaIdString(Uint8List bytes) => _albumIdString(bytes);

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

// _recordFromEnvelope : convert an UploadEnvelope (what FilePipeline produces)
// into a MediaRecord (what GET /media would return for the same row). Lets the
// tests exercise the full round trip without a live HTTP server
MediaRecord _recordFromEnvelope({
  required UploadEnvelope env,
  required Uint8List albumIdBytes,
}) {
  return MediaRecord(
    id: _mediaIdString(env.mediaId),
    albumId: _albumIdString(albumIdBytes),
    uploaderToken: 'dGVzdHRva2VuMTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMg==',
    wrapNonce: env.wrapNonce,
    wrapTagCT: env.wrapTagCT,
    epochTag: env.epoch,
    blobSize: env.blobSize,
    blobSha256: env.blobSha256,
    mediaType: env.mediaType,
    mimeType: env.mimeType,
    createdAt: DateTime.utc(2026, 5, 11, 12),
  );
}

void main() {
  group('FileDecryptor round trip', () {
    test('small file (VER=0x01) decrypts to identical bytes', () async {
      final aks = await _newAks(_albumIdBytes(), 3, _mk());
      final pt = _bytes(100 * 1024);
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumIdBytes(),
        currentEpoch: 3,
        plaintext: pt,
        mediaType: 'photo',
      );
      final rec = _recordFromEnvelope(env: env, albumIdBytes: _albumIdBytes());

      final got = await FileDecryptor.downloadAndDecrypt(
        aks: aks,
        record: rec,
        presignedUrl: 'http://s3/test',
        download: (_) async => env.cipherBytes,
      );
      expect(got, equals(pt));
    });

    test('large file (VER=0x03) decrypts to identical bytes', () async {
      final aks = await _newAks(_albumIdBytes(), 0, _mk());
      final pt = _bytes(2 * kSegmentSize + 100);
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumIdBytes(),
        currentEpoch: 0,
        plaintext: pt,
        mediaType: 'photo',
      );
      final rec = _recordFromEnvelope(env: env, albumIdBytes: _albumIdBytes());

      final got = await FileDecryptor.downloadAndDecrypt(
        aks: aks,
        record: rec,
        presignedUrl: 'http://s3/test',
        download: (_) async => env.cipherBytes,
      );
      expect(got, equals(pt));
    });
  });

  group('FileDecryptor attack defenses', () {
    test('server flips epoch_tag -> wrap_auth_failed', () async {
      // Install MK at epochs 3 AND 4 : encrypt under epoch 3 : pretend record
      // says epoch 4. AAD (album_id ‖ u32_be(epoch)) differs : AEAD unwrap fails
      final aks = await _newAks(_albumIdBytes(), 3, _mk(0x33));
      await aks.installVerified(
          albumId: _albumIdBytes(), epoch: 4, mk: _mk(0x44), backfill: false);
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumIdBytes(),
        currentEpoch: 3,
        plaintext: _bytes(2048),
        mediaType: 'photo',
      );
      // Forge a record claiming epoch 4 (server tampered)
      final tampered = MediaRecord(
        id: _mediaIdString(env.mediaId),
        albumId: _albumIdString(_albumIdBytes()),
        uploaderToken: 'dGVzdA==',
        wrapNonce: env.wrapNonce,
        wrapTagCT: env.wrapTagCT,
        epochTag: 4, // tampered
        blobSize: env.blobSize,
        blobSha256: env.blobSha256,
        mediaType: env.mediaType,
        mimeType: env.mimeType,
        createdAt: DateTime.utc(2026, 5, 11),
      );

      await expectLater(
        FileDecryptor.downloadAndDecrypt(
          aks: aks,
          record: tampered,
          presignedUrl: 'http://s3/test',
          download: (_) async => env.cipherBytes,
        ),
        throwsA(isA<FileDecryptError>()
            .having((e) => e.reason, 'reason', 'wrap_auth_failed')),
      );
    });

    test('ciphertext bit flip -> sha256_mismatch (caught before AEAD)',
        () async {
      final aks = await _newAks(_albumIdBytes(), 0, _mk());
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumIdBytes(),
        currentEpoch: 0,
        plaintext: _bytes(2048),
        mediaType: 'photo',
      );
      final rec = _recordFromEnvelope(env: env, albumIdBytes: _albumIdBytes());
      final tampered = Uint8List.fromList(env.cipherBytes);
      tampered[tampered.length ~/ 2] ^= 0x01;

      await expectLater(
        FileDecryptor.downloadAndDecrypt(
          aks: aks,
          record: rec,
          presignedUrl: 'http://s3/test',
          download: (_) async => tampered,
        ),
        throwsA(isA<FileDecryptError>()
            .having((e) => e.reason, 'reason', 'sha256_mismatch')),
      );
    });

    test('aead tamper that bypasses sha256 -> aead_auth_failed', () async {
      // Bypass the sha256 sanity check by tampering AND recomputing the hash :
      // simulates an attacker who controls both the bytes and the metadata
      final aks = await _newAks(_albumIdBytes(), 0, _mk());
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumIdBytes(),
        currentEpoch: 0,
        plaintext: _bytes(2048),
        mediaType: 'photo',
      );
      final tampered = Uint8List.fromList(env.cipherBytes);
      tampered[tampered.length ~/ 2] ^= 0x01;
      final tamperedHash = await cg.Sha256().hash(tampered);

      final rec = MediaRecord(
        id: _mediaIdString(env.mediaId),
        albumId: _albumIdString(_albumIdBytes()),
        uploaderToken: 'dGVzdA==',
        wrapNonce: env.wrapNonce,
        wrapTagCT: env.wrapTagCT,
        epochTag: env.epoch,
        blobSize: tampered.length,
        blobSha256: Uint8List.fromList(tamperedHash.bytes),
        mediaType: env.mediaType,
        mimeType: env.mimeType,
        createdAt: DateTime.utc(2026, 5, 11),
      );

      await expectLater(
        FileDecryptor.downloadAndDecrypt(
          aks: aks,
          record: rec,
          presignedUrl: 'http://s3/test',
          download: (_) async => tampered,
        ),
        throwsA(isA<FileDecryptError>()
            .having((e) => e.reason, 'reason', 'aead_auth_failed')),
      );
    });

    test('size mismatch -> wrong_size', () async {
      final aks = await _newAks(_albumIdBytes(), 0, _mk());
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumIdBytes(),
        currentEpoch: 0,
        plaintext: _bytes(2048),
        mediaType: 'photo',
      );
      final rec = _recordFromEnvelope(env: env, albumIdBytes: _albumIdBytes());
      final truncated =
          Uint8List.sublistView(env.cipherBytes, 0, env.cipherBytes.length - 5);

      await expectLater(
        FileDecryptor.downloadAndDecrypt(
          aks: aks,
          record: rec,
          presignedUrl: 'http://s3/test',
          download: (_) async => truncated,
        ),
        throwsA(isA<FileDecryptError>()
            .having((e) => e.reason, 'reason', 'wrong_size')),
      );
    });

    test('no MK installed for epoch -> no_mk', () async {
      final aks = await _newAks(_albumIdBytes(), 3, _mk());
      // Prepare under epoch 3 : then ask decryptor for a record at epoch 5
      // (no MK installed). Should bail with no_mk before any download
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumIdBytes(),
        currentEpoch: 3,
        plaintext: _bytes(2048),
        mediaType: 'photo',
      );
      final rec = MediaRecord(
        id: _mediaIdString(env.mediaId),
        albumId: _albumIdString(_albumIdBytes()),
        uploaderToken: 'dGVzdA==',
        wrapNonce: env.wrapNonce,
        wrapTagCT: env.wrapTagCT,
        epochTag: 5, // no MK installed at epoch 5
        blobSize: env.blobSize,
        blobSha256: env.blobSha256,
        mediaType: env.mediaType,
        mimeType: env.mimeType,
        createdAt: DateTime.utc(2026, 5, 11),
      );
      var downloadCalled = false;

      await expectLater(
        FileDecryptor.downloadAndDecrypt(
          aks: aks,
          record: rec,
          presignedUrl: 'http://s3/test',
          download: (_) async {
            downloadCalled = true;
            return env.cipherBytes;
          },
        ),
        throwsA(
            isA<FileDecryptError>().having((e) => e.reason, 'reason', 'no_mk')),
      );
      expect(downloadCalled, isFalse,
          reason: 'no_mk must short circuit before any HTTP work');
    });

    test('http download failure -> http_failed', () async {
      final aks = await _newAks(_albumIdBytes(), 0, _mk());
      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: _albumIdBytes(),
        currentEpoch: 0,
        plaintext: _bytes(2048),
        mediaType: 'photo',
      );
      final rec = _recordFromEnvelope(env: env, albumIdBytes: _albumIdBytes());

      await expectLater(
        FileDecryptor.downloadAndDecrypt(
          aks: aks,
          record: rec,
          presignedUrl: 'http://s3/test',
          download: (_) async => throw Exception('network down'),
        ),
        throwsA(isA<FileDecryptError>()
            .having((e) => e.reason, 'reason', 'http_failed')),
      );
    });
  });
}
