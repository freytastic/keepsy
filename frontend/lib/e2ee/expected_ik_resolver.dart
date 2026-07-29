import 'dart:typed_data';

typedef SelfTokenLookup = Uint8List? Function(Uint8List albumId);
typedef PinnedIkLookup = Uint8List? Function(
    Uint8List albumId, Uint8List memberToken);
typedef CurrentIkLookup = Future<Uint8List> Function();

// Thrown when a remaining member has no TOFU pin at rotation time : the album
// stays in pending rotation until the roster is reconciled. Fail closed rather
// than TOFU here : a server that timed a substituted bundle to the post kick
// rotation would otherwise become the "first sight" and receive the new MK
class MissingIdentityPinException implements Exception {
  final Uint8List memberToken;
  const MissingIdentityPinException(this.memberToken);
  @override
  String toString() => 'MissingIdentityPinException(no pinned identity)';
}

// Resolves the IK an MK wrap must be bound to for member removal / pending
// rotation recovery. The local member's own token resolves to currentIkPub
// (our trust design deliberately never pins "me") : every other member MUST
// carry a pinned key, and a miss fails closed
class ExpectedIkResolver {
  final SelfTokenLookup _selfToken;
  final PinnedIkLookup _pinned;
  final CurrentIkLookup _currentIk;

  ExpectedIkResolver({
    required SelfTokenLookup selfToken,
    required PinnedIkLookup pinned,
    required CurrentIkLookup currentIk,
  })  : _selfToken = selfToken,
        _pinned = pinned,
        _currentIk = currentIk;

  Future<Uint8List> call(Uint8List albumId, Uint8List memberToken) async {
    final self = _selfToken(albumId);
    if (self != null && _eq(self, memberToken)) return _currentIk();
    final pinned = _pinned(albumId, memberToken);
    if (pinned == null) throw MissingIdentityPinException(memberToken);
    return pinned;
  }

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
