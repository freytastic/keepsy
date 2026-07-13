import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/crypto/safety_numbers.dart';
import 'package:keepsy/data/storage/identity_pin_store.dart';
import 'package:keepsy/e2ee/identity_trust.dart';

import '../_sodium_setup.dart';
import '_admin_test_helpers.dart';

Uint8List _albumId(int b) => Uint8List.fromList(List<int>.filled(16, b));
Uint8List _ik(int b) => Uint8List.fromList(List<int>.filled(32, b));

void main() {
  setUpAll(ensureSodium);

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('trust'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<({IdentityTrust trust, IdentityPinStore store, Uint8List myIk})>
      newTrust() async {
    final me = await newResponderIdentity();
    final store = await IdentityPinStore.open(
      file: File('${dir.path}/pins.kec'),
      cacheRootKey: Uint8List.fromList(List<int>.filled(32, 5)),
    );
    return (
      trust: IdentityTrust(identity: me.svc, pins: store),
      store: store,
      myIk: await me.svc.currentIkPub(),
    );
  }

  group('reconcile', () {
    test('first sight silently pins the key and reports unverified', () async {
      final t = await newTrust();
      final alb = _albumId(1);

      final states = await t.trust
          .reconcile(alb, [PeerIdentity(memberToken: 'bob', ikPub: _ik(2))]);

      // TOFU : a never seen member is not an alarm, but it is NOT "safe" either
      expect(states['bob'], TrustState.unverified);
      expect(t.store.pinnedIk(hexAlbumId(alb), 'bob'), _ik(2));
    });

    test('an unchanged key on a later reconcile stays unverified', () async {
      final t = await newTrust();
      final alb = _albumId(1);
      final roster = [PeerIdentity(memberToken: 'bob', ikPub: _ik(2))];

      await t.trust.reconcile(alb, roster);
      final states = await t.trust.reconcile(alb, roster);

      expect(states['bob'], TrustState.unverified);
    });

    test('a different ik_pub under the same member token reports changed',
        () async {
      final t = await newTrust();
      final alb = _albumId(1);
      await t.trust
          .reconcile(alb, [PeerIdentity(memberToken: 'bob', ikPub: _ik(2))]);

      // the server now hands us a DIFFERENT key for the same roster slot
      final states = await t.trust
          .reconcile(alb, [PeerIdentity(memberToken: 'bob', ikPub: _ik(3))]);

      expect(states['bob'], TrustState.changed);
      // and the pin must NOT quietly move : the user has to resolve it
      expect(t.store.pinnedIk(hexAlbumId(alb), 'bob'), _ik(2));
    });

    test('our own roster row is skipped : no safety number with ourselves',
        () async {
      final t = await newTrust();

      final states = await t.trust.reconcile(
          _albumId(1),
          [
            PeerIdentity(memberToken: 'me', ikPub: t.myIk),
            PeerIdentity(memberToken: 'bob', ikPub: _ik(2)),
          ],
          myMemberToken: 'me');

      expect(states.containsKey('me'), isFalse);
      expect(states['bob'], TrustState.unverified);
    });

    // Self MUST be identified by the member token we hold, never by the ik_pub
    // the SERVER put in the row : otherwise a server can silence a peer's key
    // change alarm just by claiming that peer's key is our own
    test('a peer row carrying OUR ik_pub is flagged, not silently skipped',
        () async {
      final t = await newTrust();
      final alb = _albumId(1);
      await t.trust.reconcile(
          alb, [PeerIdentity(memberToken: 'bob', ikPub: _ik(2))],
          myMemberToken: 'me');

      // the server swaps Bob's roster key for OUR OWN identity key
      final states = await t.trust.reconcile(
          alb, [PeerIdentity(memberToken: 'bob', ikPub: t.myIk)],
          myMemberToken: 'me');

      expect(states['bob'], TrustState.changed);
    });

    // a first sight is the whole TOFU baseline : an app kill 400ms later must
    // not be able to erase it and let a substituted key become the new baseline
    test('a first sight pin is durable before reconcile returns', () async {
      final t = await newTrust();
      final alb = _albumId(1);

      await t.trust
          .reconcile(alb, [PeerIdentity(memberToken: 'bob', ikPub: _ik(2))]);

      // NO explicit flush : reopen straight off disk, as a cold start would
      final reopened = await IdentityPinStore.open(
        file: File('${dir.path}/pins.kec'),
        cacheRootKey: Uint8List.fromList(List<int>.filled(32, 5)),
      );
      expect(reopened.pinnedIk(hexAlbumId(alb), 'bob'), _ik(2));
    });
  });

  group('verification', () {
    test('markVerified turns the peer verified', () async {
      final t = await newTrust();
      final alb = _albumId(1);
      final roster = [PeerIdentity(memberToken: 'bob', ikPub: _ik(2))];
      await t.trust.reconcile(alb, roster);

      await t.trust
          .markVerified(albumId: alb, memberToken: 'bob', peerIkPub: _ik(2));

      expect(
          (await t.trust.reconcile(alb, roster))['bob'], TrustState.verified);
    });

    // The whole point of keying the verified set on the IK rather than the
    // album : you confirmed Bob's KEY, and that key is the same everywhere
    test('verifying a peer once carries into every album you share', () async {
      final t = await newTrust();
      await t.trust.reconcile(
          _albumId(1), [PeerIdentity(memberToken: 'bob-a', ikPub: _ik(2))]);
      await t.trust.markVerified(
          albumId: _albumId(1), memberToken: 'bob-a', peerIkPub: _ik(2));

      // a DIFFERENT album, where Bob has a different pseudonymous token
      final states = await t.trust.reconcile(
          _albumId(9), [PeerIdentity(memberToken: 'bob-z', ikPub: _ik(2))]);

      expect(states['bob-z'], TrustState.verified);
    });

    test('a verified peer whose key then changes reports changed, not verified',
        () async {
      final t = await newTrust();
      final alb = _albumId(1);
      await t.trust
          .reconcile(alb, [PeerIdentity(memberToken: 'bob', ikPub: _ik(2))]);
      await t.trust
          .markVerified(albumId: alb, memberToken: 'bob', peerIkPub: _ik(2));

      final states = await t.trust
          .reconcile(alb, [PeerIdentity(memberToken: 'bob', ikPub: _ik(3))]);

      expect(states['bob'], TrustState.changed);
    });

    // Verifying a key MEANS pinning it : the user read these exact digits back
    // to the human. Without the re pin the old pin survives and the next
    // reconcile still screams "changed" at someone who just verified
    test('verifying a CHANGED key re-pins it and clears the alarm', () async {
      final t = await newTrust();
      final alb = _albumId(1);
      await t.trust
          .reconcile(alb, [PeerIdentity(memberToken: 'bob', ikPub: _ik(2))]);
      final newRoster = [PeerIdentity(memberToken: 'bob', ikPub: _ik(3))];
      expect(
          (await t.trust.reconcile(alb, newRoster))['bob'], TrustState.changed);

      // they got a new phone, read the new digits back, and they match
      await t.trust
          .markVerified(albumId: alb, memberToken: 'bob', peerIkPub: _ik(3));

      expect((await t.trust.reconcile(alb, newRoster))['bob'],
          TrustState.verified);
      expect(t.store.pinnedIk(hexAlbumId(alb), 'bob'), _ik(3));
    });

    test('acceptChange re-pins the new key and leaves it unverified', () async {
      final t = await newTrust();
      final alb = _albumId(1);
      await t.trust
          .reconcile(alb, [PeerIdentity(memberToken: 'bob', ikPub: _ik(2))]);
      await t.trust
          .markVerified(albumId: alb, memberToken: 'bob', peerIkPub: _ik(2));
      final newRoster = [PeerIdentity(memberToken: 'bob', ikPub: _ik(3))];
      await t.trust.reconcile(alb, newRoster);

      await t.trust
          .acceptChange(albumId: alb, memberToken: 'bob', peerIkPub: _ik(3));

      expect((await t.trust.reconcile(alb, newRoster))['bob'],
          TrustState.unverified);
      expect(t.store.pinnedIk(hexAlbumId(alb), 'bob'), _ik(3));
    });
  });

  group('safety number', () {
    // Both sides must read the same digits or the whole ritual is useless
    test('is symmetric : each side computes the same digits for the other',
        () async {
      final alice = await newTrust();
      final bob = await newTrust();
      final alb = _albumId(4);

      final aSees =
          await alice.trust.safetyNumber(albumId: alb, peerIkPub: bob.myIk);
      final bSees =
          await bob.trust.safetyNumber(albumId: alb, peerIkPub: alice.myIk);

      expect(aSees, bSees);
      expect(aSees, matches(RegExp(r'^(\d{5} ){5}\d{5}$')));
    });

    test('a MITM substituted peer key yields digits that do not match',
        () async {
      final alice = await newTrust();
      final bob = await newTrust();
      final mallory = await newTrust();
      final alb = _albumId(4);

      // the server feeds Alice Mallory's key while claiming it is Bob's
      final aliceSees =
          await alice.trust.safetyNumber(albumId: alb, peerIkPub: mallory.myIk);
      final bobSees =
          await bob.trust.safetyNumber(albumId: alb, peerIkPub: alice.myIk);

      // reading the digits aloud is what catches it
      expect(aliceSees, isNot(bobSees));
    });

    test('matches the frozen SafetyNumber primitive', () async {
      final t = await newTrust();
      final alb = _albumId(4);

      final viaTrust =
          await t.trust.safetyNumber(albumId: alb, peerIkPub: _ik(2));
      final direct = await SafetyNumber.formatted(
          ikPubA: t.myIk, ikPubB: _ik(2), albumId: alb);

      expect(viaTrust, direct);
    });
  });

  test('forgetAlbum drops that album\'s pins', () async {
    final t = await newTrust();
    final alb = _albumId(1);
    await t.trust
        .reconcile(alb, [PeerIdentity(memberToken: 'bob', ikPub: _ik(2))]);

    await t.trust.forgetAlbum(alb);

    expect(t.store.pinnedIk(hexAlbumId(alb), 'bob'), isNull);
  });
}
