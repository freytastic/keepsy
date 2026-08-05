import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/storage/identity_pin_store.dart';

Uint8List _key(int b) => Uint8List.fromList(List<int>.filled(32, b));
Uint8List _ik(int b) => Uint8List.fromList(List<int>.filled(32, b));

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('pinstore'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File pinFile() => File('${dir.path}/pins.kec');

  test('pin is recorded per (album, memberToken)', () async {
    final s =
        await IdentityPinStore.open(file: pinFile(), cacheRootKey: _key(1));

    expect(s.pinnedIk('alb', 'tok'), isNull);
    s.pin('alb', 'tok', _ik(9));

    expect(s.pinnedIk('alb', 'tok'), _ik(9));
    // the same person's token in another album is a separate pin
    expect(s.pinnedIk('other', 'tok'), isNull);
    expect(s.pinnedIk('alb', 'other-tok'), isNull);
  });

  test('pins and verifications survive a reopen with the same key', () async {
    final s1 =
        await IdentityPinStore.open(file: pinFile(), cacheRootKey: _key(7));
    s1.pin('alb', 'tok', _ik(3));
    s1.markVerified(myIkPub: _ik(1), peerIkPub: _ik(3));
    await s1.flush();

    final s2 =
        await IdentityPinStore.open(file: pinFile(), cacheRootKey: _key(7));
    expect(s2.pinnedIk('alb', 'tok'), _ik(3));
    expect(s2.isVerified(myIkPub: _ik(1), peerIkPub: _ik(3)), isTrue);
  });

  test('a wrong cache key yields an empty store, not a crash', () async {
    final s1 =
        await IdentityPinStore.open(file: pinFile(), cacheRootKey: _key(7));
    s1.pin('alb', 'tok', _ik(3));
    await s1.flush();

    final s2 =
        await IdentityPinStore.open(file: pinFile(), cacheRootKey: _key(8));
    expect(s2.pinnedIk('alb', 'tok'), isNull);
  });

  // The verified set is keyed (myIkPub, peerIkPub) : "this device identity
  // confirmed that peer identity key". Not album scoped, not peer only
  test('verification is bound to BOTH the local and the peer identity key',
      () async {
    final s =
        await IdentityPinStore.open(file: pinFile(), cacheRootKey: _key(1));
    s.markVerified(myIkPub: _ik(1), peerIkPub: _ik(2));

    expect(s.isVerified(myIkPub: _ik(1), peerIkPub: _ik(2)), isTrue);
    // a different local identity has verified nothing
    expect(s.isVerified(myIkPub: _ik(9), peerIkPub: _ik(2)), isFalse);
    // and the peer's NEW key is not verified just because their old one was
    expect(s.isVerified(myIkPub: _ik(1), peerIkPub: _ik(3)), isFalse);
  });

  test('clearAlbum drops that album\'s pins but keeps verifications', () async {
    final s =
        await IdentityPinStore.open(file: pinFile(), cacheRootKey: _key(1));
    s.pin('alb', 'tok', _ik(3));
    s.pin('keep', 'tok2', _ik(4));
    s.markVerified(myIkPub: _ik(1), peerIkPub: _ik(3));

    await s.clearAlbum('alb');

    expect(s.pinnedIk('alb', 'tok'), isNull);
    expect(s.pinnedIk('keep', 'tok2'), _ik(4));
    // we still know that key is really theirs : that fact isnt album scoped
    expect(s.isVerified(myIkPub: _ik(1), peerIkPub: _ik(3)), isTrue);
  });

  test('clear wipes pins, verifications and the file', () async {
    final s =
        await IdentityPinStore.open(file: pinFile(), cacheRootKey: _key(1));
    s.pin('alb', 'tok', _ik(3));
    s.markVerified(myIkPub: _ik(1), peerIkPub: _ik(3));
    await s.flush();

    await s.clear();

    expect(s.pinnedIk('alb', 'tok'), isNull);
    expect(s.isVerified(myIkPub: _ik(1), peerIkPub: _ik(3)), isFalse);
    expect(pinFile().existsSync(), isFalse);
  });

  test('a signer binding is separate from a roster pin', () async {
    // Opening the member list TOFU pins every unseen roster row. That must not
    // silently grant the same token authority to sign epoch transitions
    final s =
        await IdentityPinStore.open(file: pinFile(), cacheRootKey: _key(1));
    s.pin('alb', 'bob', _ik(2));

    expect(s.pinnedIk('alb', 'bob'), _ik(2));
    expect(s.signerIk('alb', 'bob'), isNull);
  });

  test('signer bindings and creating marks survive a reopen', () async {
    final s =
        await IdentityPinStore.open(file: pinFile(), cacheRootKey: _key(7));
    s.pinSigner('alb', 'bob', _ik(3));
    await s.markCreating('alb2');
    await s.flush();

    final reopened =
        await IdentityPinStore.open(file: pinFile(), cacheRootKey: _key(7));

    expect(reopened.signerIk('alb', 'bob'), _ik(3));
    expect(reopened.isCreating('alb2'), isTrue);
  });

  test('creatingAlbums lists the marks a boot reconcile has to inspect',
      () async {
    final s =
        await IdentityPinStore.open(file: pinFile(), cacheRootKey: _key(1));
    await s.markCreating('alb');

    expect(s.creatingAlbums, ['alb']);
    await s.clearCreating('alb');
    expect(s.creatingAlbums, isEmpty);
  });

  test('clearAlbum drops that album signer bindings and creating mark',
      () async {
    final s =
        await IdentityPinStore.open(file: pinFile(), cacheRootKey: _key(1));
    s.pinSigner('alb', 'bob', _ik(3));
    await s.markCreating('alb');

    await s.clearAlbum('alb');

    expect(s.signerIk('alb', 'bob'), isNull);
    expect(s.isCreating('alb'), isFalse);
  });
}
