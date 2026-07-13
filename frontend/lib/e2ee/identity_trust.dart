import 'dart:typed_data';

import 'package:keepsy/crypto/safety_numbers.dart';
import 'package:keepsy/data/storage/identity_pin_store.dart';
import 'package:keepsy/e2ee/identity.dart';

// TOFU trust over the album roster. Fully local + advisory : nothing here
// gates X3DH, uploads or fetches. A false positive (a fren reinstalled) must
// never lock a user out of their own album, and a real substitution is still
// VISIBLE, which is the whole point of a safety number
enum TrustState {
  // seen, pinned, never compared out of band. NOT a claim of safety : a MITM
  // present at the very first sight is exactly what TOFU cannot rule out
  unverified,
  // the digits were read back to us by the human, and the key hasnt moved since
  verified,
  // the SAME member token is being presented with a DIFFERENT ik_pub. Either
  // they re installed, or the server is lying to us
  changed,
}

class PeerIdentity {
  final String memberToken; // base64, stable per (user, album)
  final Uint8List ikPub; // 32B Ed25519, as served in the roster
  const PeerIdentity({required this.memberToken, required this.ikPub});
}

// The pin store takes an opaque album key : everything album scoped in e2ee/
// speaks 16 raw bytes, so hex them at the boundary rather than plumbing both
String hexAlbumId(Uint8List albumId) =>
    albumId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class IdentityTrust {
  final IdentityService _identity;
  final IdentityPinStore _pins;

  IdentityTrust(
      {required IdentityService identity, required IdentityPinStore pins})
      : _identity = identity,
        _pins = pins;

  // Pins anyone we havent seen before, then classifies. A changed key is NOT
  // re pinned here : moving the pin is the user's call (markVerified/acceptChange)

  // myMemberToken identifies OUR row. It must be the token we hold locally and
  // NEVER an ik_pub comparison : a server that could get us to skip a row by
  // choosing what key to put in it could silence a peer's change alarm just by
  // claiming that peer's key is our own. A row that isnt ours but carries our
  // ik_pub is an anomaly, and falls through to 'changed' exactly as it should
  Future<Map<String, TrustState>> reconcile(
    Uint8List albumId,
    List<PeerIdentity> roster, {
    String? myMemberToken,
  }) async {
    final myIk = await _identity.currentIkPub();
    final album = hexAlbumId(albumId);
    final out = <String, TrustState>{};
    var pinnedAny = false;

    for (final peer in roster) {
      if (peer.memberToken == myMemberToken) continue;
      final pinned = _pins.pinnedIk(album, peer.memberToken);
      if (pinned == null) {
        _pins.pin(album, peer.memberToken, peer.ikPub);
        pinnedAny = true;
      } else if (!_eq(pinned, peer.ikPub)) {
        out[peer.memberToken] = TrustState.changed;
        continue;
      }
      // Runs on a first sight too : the same peer in a new album shows up with
      // a fresh token but the SAME ik_pub, and that key may already be verified
      out[peer.memberToken] =
          _pins.isVerified(myIkPub: myIk, peerIkPub: peer.ikPub)
              ? TrustState.verified
              : TrustState.unverified;
    }
    // A first sight IS the TOFU baseline : persist it before anyone can act on
    // it. A kill inside the debounce window would otherwise drop the real key
    // and let the next (possibly substituted) one become an innocent first sight
    if (pinnedAny) await _pins.flush();
    return out;
  }

  Future<String> safetyNumber({
    required Uint8List albumId,
    required Uint8List peerIkPub,
  }) async {
    final myIk = await _identity.currentIkPub();
    return SafetyNumber.formatted(
        ikPubA: myIk, ikPubB: peerIkPub, albumId: albumId);
  }

  // Verifies the key the user was ACTUALLY SHOWN, not whatever the roster says
  // by the time they tap. Verifying a key necessarily pins it : the human read
  // back these exact digits, so this IS the key now. Without the re pin, a user
  // resolving a 'changed' alarm would verify the new key and still be screamed
  // at, because the stale pin would keep winning the comparison
  Future<void> markVerified({
    required Uint8List albumId,
    required String memberToken,
    required Uint8List peerIkPub,
  }) async {
    final myIk = await _identity.currentIkPub();
    _pins.pin(hexAlbumId(albumId), memberToken, peerIkPub);
    _pins.markVerified(myIkPub: myIk, peerIkPub: peerIkPub);
    await _pins.flush();
  }

  Future<DateTime?> verifiedAt(Uint8List peerIkPub) async {
    final myIk = await _identity.currentIkPub();
    return _pins.verifiedAt(myIkPub: myIk, peerIkPub: peerIkPub);
  }

  // "yes, that really was them re installing". Moves the pin onto the new key
  // WITHOUT inheriting the old key's verification : the new key was never
  // compared out of band
  Future<void> acceptChange({
    required Uint8List albumId,
    required String memberToken,
    required Uint8List peerIkPub,
  }) async {
    _pins.pin(hexAlbumId(albumId), memberToken, peerIkPub);
    await _pins.flush();
  }

  // Revoke / leave / delete : the roster is gone, so the pins are unrefreshable
  Future<void> forgetAlbum(Uint8List albumId) =>
      _pins.clearAlbum(hexAlbumId(albumId));

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
