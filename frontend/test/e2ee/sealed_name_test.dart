import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/sealed_name.dart';

import '../_sodium_setup.dart';
import '../secure_store/mock_secure_key_store.dart';

Uint8List _albumId([int seed = 0xA1]) =>
    Uint8List.fromList(List<int>.filled(16, seed));

Uint8List _token([int seed = 0x0B]) =>
    Uint8List.fromList(List<int>.filled(32, seed));

Uint8List _mk(int b) => Uint8List.fromList(List<int>.filled(32, b));

Future<AlbumKeyStore> _storeWith(Map<int, int> epochToMkByte,
    {Uint8List? albumId}) async {
  final s = MockSecureKeyStore();
  await s.initialize();
  final aks = AlbumKeyStore(s);
  await aks.initialize();
  final id = albumId ?? _albumId();
  for (final e in epochToMkByte.entries) {
    await aks.install(id, e.key, _mk(e.value));
  }
  return aks;
}

void main() {
  setUpAll(ensureSodium);

  group('SealedName album title', () {
    test('round trips under the sealing epoch', () async {
      final id = _albumId();
      final ks = await _storeWith({0: 0x11});
      final ct = await SealedName.sealAlbumName(ks, id, 0, 'Family Trip 🏖️');
      expect(await SealedName.openAlbumName(ks, id, ct), 'Family Trip 🏖️');
    });

    test('cross-epoch: sealed @ ep2 still opens after rotation to ep3',
        () async {
      final id = _albumId();
      final ks = await _storeWith({2: 0x22});
      final ct = await SealedName.sealAlbumName(ks, id, 2, 'Beach');
      // Rotate: a later MK is installed, but the old one is retained
      await ks.install(id, 3, _mk(0x33));
      expect(await SealedName.openAlbumName(ks, id, ct), 'Beach');
    });

    test('tampered blob -> null', () async {
      final id = _albumId();
      final ks = await _storeWith({0: 0x11});
      final ct = await SealedName.sealAlbumName(ks, id, 0, 'Secret');
      final raw = base64.decode(ct);
      raw[raw.length - 1] ^= 0xff; // flip a ciphertext byte
      expect(
          await SealedName.openAlbumName(ks, id, base64.encode(raw)), isNull);
    });

    test('wrong album id (AAD mismatch) -> null', () async {
      final id = _albumId(0xA1);
      final other = _albumId(0xB2);
      final ks = await _storeWith({0: 0x11}, albumId: id);
      // Install the same MK bytes under the other album id so useMk succeeds
      // but the AAD (album id) differs
      await ks.install(other, 0, _mk(0x11));
      final ct = await SealedName.sealAlbumName(ks, id, 0, 'Mine');
      expect(await SealedName.openAlbumName(ks, other, ct), isNull);
    });

    test('missing MK for the sealed epoch -> null', () async {
      final id = _albumId();
      final ks = await _storeWith({0: 0x11});
      final ct = await SealedName.sealAlbumName(ks, id, 0, 'Hi');
      final empty = await _storeWith(const {}); // no MKs installed
      expect(await SealedName.openAlbumName(empty, id, ct), isNull);
    });

    test('garbage base64 -> null', () async {
      final id = _albumId();
      final ks = await _storeWith({0: 0x11});
      expect(await SealedName.openAlbumName(ks, id, 'not base64 %%%'), isNull);
    });
  });

  group('SealedName member name', () {
    test('round trips bound to (album, member_token, epoch)', () async {
      final id = _albumId();
      final tok = _token();
      final ks = await _storeWith({4: 0x44});
      final ct = await SealedName.sealMemberName(ks, id, tok, 4, 'Alice');
      expect(await SealedName.openMemberName(ks, id, tok, ct), 'Alice');
    });

    test('different member_token (AAD mismatch) -> null', () async {
      final id = _albumId();
      final ks = await _storeWith({4: 0x44});
      final ct =
          await SealedName.sealMemberName(ks, id, _token(0x0B), 4, 'Bob');
      expect(await SealedName.openMemberName(ks, id, _token(0x0C), ct), isNull);
    });

    test('an album name blob does not open as a member name', () async {
      final id = _albumId();
      final tok = _token();
      final ks = await _storeWith({4: 0x44});
      final ct = await SealedName.sealAlbumName(ks, id, 4, 'Title');
      expect(await SealedName.openMemberName(ks, id, tok, ct), isNull);
    });
  });

  group('SealedName.openMemberNames (batch)', () {
    test('decrypts many members sharing one epoch', () async {
      final id = _albumId();
      final ks = await _storeWith({3: 0x33});
      final tA = _token(0x0A), tB = _token(0x0B);
      final ctA = await SealedName.sealMemberName(ks, id, tA, 3, 'Alice');
      final ctB = await SealedName.sealMemberName(ks, id, tB, 3, 'Bob');
      final out = await SealedName.openMemberNames(ks, id, [
        (token: 'A', tokenBytes: tA, nameCt: ctA),
        (token: 'B', tokenBytes: tB, nameCt: ctB),
      ]);
      expect(out, {'A': 'Alice', 'B': 'Bob'});
    });

    test('handles members across different epochs', () async {
      final id = _albumId();
      final ks = await _storeWith({2: 0x22, 5: 0x55});
      final tA = _token(0x0A), tB = _token(0x0B);
      final ctA = await SealedName.sealMemberName(ks, id, tA, 2, 'Old');
      final ctB = await SealedName.sealMemberName(ks, id, tB, 5, 'New');
      final out = await SealedName.openMemberNames(ks, id, [
        (token: 'A', tokenBytes: tA, nameCt: ctA),
        (token: 'B', tokenBytes: tB, nameCt: ctB),
      ]);
      expect(out, {'A': 'Old', 'B': 'New'});
    });

    test('skips entries whose MK is missing, keeps the rest', () async {
      final id = _albumId();
      final ks = await _storeWith({2: 0x22}); // epoch 5 not installed
      final tA = _token(0x0A), tB = _token(0x0B);
      final ctA = await SealedName.sealMemberName(ks, id, tA, 2, 'Here');
      // Seal 'Gone' under an epoch we then dont keep installed.\
      final ks5 = await _storeWith({5: 0x55});
      final ctB = await SealedName.sealMemberName(ks5, id, tB, 5, 'Gone');
      final out = await SealedName.openMemberNames(ks, id, [
        (token: 'A', tokenBytes: tA, nameCt: ctA),
        (token: 'B', tokenBytes: tB, nameCt: ctB),
      ]);
      expect(out, {'A': 'Here'});
    });
  });
}
