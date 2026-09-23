import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/sealed_avatar.dart';

import '../_sodium_setup.dart';
import '../secure_store/mock_secure_key_store.dart';

Uint8List _fill(int n, int b) => Uint8List.fromList(List<int>.filled(n, b));

final _album = _fill(16, 0xA1);
final _me = _fill(32, 0x0B);
final _jpeg = Uint8List.fromList(List<int>.generate(5000, (i) => i % 251));

Future<AlbumKeyStore> _keys(Map<int, int> epochs, {Uint8List? album}) async {
  final s = MockSecureKeyStore();
  await s.initialize();
  final aks = AlbumKeyStore(s);
  await aks.initialize();
  for (final e in epochs.entries) {
    await aks.install(album ?? _album, e.key, _fill(32, e.value));
  }
  return aks;
}

Future<Uint8List?> _open(AlbumKeyStore ks, SealedAvatar a,
        {Uint8List? album, Uint8List? token, Uint8List? blob}) =>
    AvatarCrypto.open(
      ks: ks,
      albumId: album ?? _album,
      memberToken: token ?? _me,
      avatarId: a.avatarId,
      keyCt: a.keyCt,
      blobSha256: a.blobSha256,
      blob: blob ?? a.blob,
    );

void main() {
  setUpAll(ensureSodium);

  test('round trips and hides the jpeg size behind fixed padding', () async {
    final ks = await _keys({0: 0x11});
    final a = await AvatarCrypto.seal(
        ks: ks, albumId: _album, memberToken: _me, jpeg: _jpeg);
    final small = await AvatarCrypto.seal(
        ks: ks, albumId: _album, memberToken: _me, jpeg: _fill(10, 1));

    expect(await _open(ks, a), _jpeg);
    expect(a.blob.length, kAvatarBlobBytes);
    expect(small.blob.length, a.blob.length);
    // Pinned by the server's key_ct length check
    expect(a.keyCt.length, 65);
    expect(a.blobSha256, (await cg.Sha256().hash(a.blob)).bytes);
  });

  test('every copy gets a fresh id and key', () async {
    final ks = await _keys({0: 0x11});
    final a = await AvatarCrypto.seal(
        ks: ks, albumId: _album, memberToken: _me, jpeg: _jpeg);
    final b = await AvatarCrypto.seal(
        ks: ks, albumId: _album, memberToken: _me, jpeg: _jpeg);
    expect(a.avatarId, isNot(b.avatarId));
    expect(a.blobSha256, isNot(b.blobSha256));
  });

  test('opens after the album rotates to a newer key', () async {
    final ks = await _keys({2: 0x22});
    final a = await AvatarCrypto.seal(
        ks: ks, albumId: _album, memberToken: _me, jpeg: _jpeg);
    await ks.install(_album, 3, _fill(32, 0x33));
    expect(await _open(ks, a), _jpeg);
  });

  test('cannot be moved onto another member or album', () async {
    final other = _fill(16, 0xB2);
    final ks = await _keys({0: 0x11});
    await ks.install(other, 0, _fill(32, 0x11));
    final a = await AvatarCrypto.seal(
        ks: ks, albumId: _album, memberToken: _me, jpeg: _jpeg);

    expect(await _open(ks, a, token: _fill(32, 0x0C)), isNull);
    expect(await _open(ks, a, album: other), isNull);
  });

  test('refuses a swapped or tampered blob', () async {
    final ks = await _keys({0: 0x11});
    final a = await AvatarCrypto.seal(
        ks: ks, albumId: _album, memberToken: _me, jpeg: _jpeg);
    final b = await AvatarCrypto.seal(
        ks: ks, albumId: _album, memberToken: _me, jpeg: _fill(10, 1));

    expect(await _open(ks, a, blob: b.blob), isNull);
    final flipped = Uint8List.fromList(a.blob)..[40] ^= 1;
    expect(await _open(ks, a, blob: flipped), isNull);
  });

  test('needs an album key and a jpeg that fits', () async {
    final none = await _keys({});
    await expectLater(
        AvatarCrypto.seal(
            ks: none, albumId: _album, memberToken: _me, jpeg: _jpeg),
        throwsStateError);
    final ks = await _keys({0: 0x11});
    await expectLater(
        AvatarCrypto.seal(
            ks: ks,
            albumId: _album,
            memberToken: _me,
            jpeg: _fill(kAvatarMaxJpegBytes + 1, 1)),
        throwsArgumentError);
  });
}
