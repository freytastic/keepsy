import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:keepsy/crypto/wire_format.dart';

void main() {
  group('L9 salts: expected ASCII bytes', () {
    final expected = <Uint8List, String>{
      kSaltX3dh: 'vault-x3dh-v1',
      kSaltInvite: 'invite-v1',
      kSaltSegNonce: 'seg-nonce-v1',
      kSaltKeyConfirm: 'key-confirm-v1',
      kSaltManifest: 'manifest-v1',
      kSaltSpkRotate: 'rotate-spk-v1',
      kSaltPromote: 'promote-v1',
      kSaltJoinComplete: 'join-complete-v1',
      kSaltAlbumNameHint: 'album-name-v1',
    };

    expected.forEach((salt, ascii) {
      test(ascii, () {
        final want = Uint8List.fromList(ascii.codeUnits);
        expect(salt, orderedEquals(want));
      });
    });
  });

  group('VER constants: fixed byte values', () {
    test('AES-GCM is 0x01', () => expect(kVerAesGcm, equals(0x01)));
    test('ChaCha-Poly is 0x02', () => expect(kVerChaPo, equals(0x02)));
    test('streaming GCM is 0x03', () => expect(kVerStreamGcm, equals(0x03)));
  });

  test('segment size is 1 MiB', () {
    expect(kSegmentSize, equals(1048576));
  });

  group('kX3dhInfoConstruction', () {
    test('layout: lkA || lkB || albumId, total 80 bytes', () {
      final lkA = Uint8List.fromList(List.filled(32, 0x11));
      final lkB = Uint8List.fromList(List.filled(32, 0x22));
      final album = Uint8List.fromList(List.filled(16, 0x33));

      final out = kX3dhInfoConstruction(lkA, lkB, album);

      expect(out.length, equals(80));
      expect(out.sublist(0, 32), orderedEquals(lkA));
      expect(out.sublist(32, 64), orderedEquals(lkB));
      expect(out.sublist(64, 80), orderedEquals(album));
    });

    test('rejects wrong-size lkA', () {
      expect(
        () => kX3dhInfoConstruction(
          Uint8List(31),
          Uint8List(32),
          Uint8List(16),
        ),
        throwsArgumentError,
      );
    });

    test('rejects wrong-size lkB', () {
      expect(
        () => kX3dhInfoConstruction(
          Uint8List(32),
          Uint8List(33),
          Uint8List(16),
        ),
        throwsArgumentError,
      );
    });

    test('rejects wrong-size albumId', () {
      expect(
        () => kX3dhInfoConstruction(
          Uint8List(32),
          Uint8List(32),
          Uint8List(15),
        ),
        throwsArgumentError,
      );
    });
  });
}
