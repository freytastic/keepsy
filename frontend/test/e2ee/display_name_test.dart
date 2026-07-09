import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/crypto/uuid_bytes.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/display_name.dart';
import 'package:keepsy/e2ee/sealed_name.dart';

import '../_sodium_setup.dart';
import '../secure_store/mock_secure_key_store.dart';

Uint8List _mk(int b) => Uint8List.fromList(List<int>.filled(32, b));
Uint8List _token(int b) => Uint8List.fromList(List<int>.filled(32, b));

const _albumA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const _albumB = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

Future<AlbumKeyStore> _newKs() async {
  final s = MockSecureKeyStore();
  await s.initialize();
  final aks = AlbumKeyStore(s);
  await aks.initialize();
  return aks;
}

void main() {
  setUpAll(ensureSodium);

  group('resolveAlbumName', () {
    test('decrypts a real sealed title', () async {
      final ks = await _newKs();
      final id = uuidToBytes(_albumA)!;
      await ks.install(id, 0, _mk(0x11));
      final ct = await SealedName.sealAlbumName(ks, id, 0, 'Ski Trip');
      expect(await resolveAlbumName(ks, id, ct), 'Ski Trip');
    });

    test('falls back to legacy base64(utf8) placeholder', () async {
      final ks = await _newKs();
      final id = uuidToBytes(_albumA)!;
      final legacy = base64.encode(utf8.encode('Old Album'));
      expect(await resolveAlbumName(ks, id, legacy), 'Old Album');
    });

    test('null / empty -> Untitled Album', () async {
      final ks = await _newKs();
      final id = uuidToBytes(_albumA)!;
      expect(await resolveAlbumName(ks, id, null), 'Untitled Album');
      expect(await resolveAlbumName(ks, id, ''), 'Untitled Album');
    });

    test('undecryptable garbage -> Untitled Album', () async {
      final ks = await _newKs();
      final id = uuidToBytes(_albumA)!;
      // Valid base64 of random bytes that are not valid utf8
      final garbage = base64.encode(Uint8List.fromList([0xff, 0xfe, 0xfd]));
      expect(await resolveAlbumName(ks, id, garbage), 'Untitled Album');
    });

    test('sealed title with a not-yet-installed MK -> Untitled (no mojibake)',
        () async {
      // Seal under one store, then resolve on a store missing that MK. The
      // legacy path must NOT fire on the sealed envelope
      final sealer = await _newKs();
      final id = uuidToBytes(_albumA)!;
      await sealer.install(id, 0, _mk(0x11));
      final ct = await SealedName.sealAlbumName(sealer, id, 0, 'Hidden');
      final empty = await _newKs(); // no MK installed
      expect(await resolveAlbumName(empty, id, ct), 'Untitled Album');
    });
  });

  group('DisplayNamePublisher', () {
    test('publishToAll seals per album and PUTs once each', () async {
      final ks = await _newKs();
      final idA = uuidToBytes(_albumA)!;
      final idB = uuidToBytes(_albumB)!;
      await ks.install(idA, 2, _mk(0x22));
      await ks.install(idB, 5, _mk(0x55));
      final tokA = _token(0x0A);
      final tokB = _token(0x0B);

      final calls = <String, String>{};
      final pub = DisplayNamePublisher(
        ks: ks,
        putProfileCt: (albumId, ct) async => calls[albumId] = ct,
      );

      await pub.publishToAll([
        (albumId: _albumA, memberToken: tokA),
        (albumId: _albumB, memberToken: tokB),
      ], 'Alice');

      expect(calls.keys.toSet(), {_albumA, _albumB});
      // Each is decryptable back to the name under its own epoch/token
      expect(await SealedName.openMemberName(ks, idA, tokA, calls[_albumA]!),
          'Alice');
      expect(await SealedName.openMemberName(ks, idB, tokB, calls[_albumB]!),
          'Alice');
    });

    test('empty name is a no-op', () async {
      final ks = await _newKs();
      final idA = uuidToBytes(_albumA)!;
      await ks.install(idA, 0, _mk(0x11));
      var called = false;
      final pub = DisplayNamePublisher(
        ks: ks,
        putProfileCt: (albumId, ct) async => called = true,
      );
      await pub
          .publishToAll([(albumId: _albumA, memberToken: _token(0x0A))], '');
      expect(called, isFalse);
    });

    test('album with no MK (latestEpoch == -1) is skipped', () async {
      final ks = await _newKs(); // nothing installed
      var called = false;
      final pub = DisplayNamePublisher(
        ks: ks,
        putProfileCt: (albumId, ct) async => called = true,
      );
      await pub.publishToAlbum(
          albumId: _albumA, memberToken: _token(0x0A), name: 'Alice');
      expect(called, isFalse);
    });
  });
}
