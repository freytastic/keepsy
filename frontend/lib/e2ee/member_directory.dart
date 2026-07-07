import 'dart:typed_data';

// Refresh on miss cache from sender_token -> {ik_pub, lk_pub}, keyed per
// album. Production wiring fetches GET /albums/{id}/members through a port
// closure so this file stays decoupled from package:keepsy/data

class MemberPubs {
  final Uint8List ikPub; // 32B Ed25519
  final Uint8List lkPub; // 32B X25519
  const MemberPubs({required this.ikPub, required this.lkPub});
}

class MemberRecord {
  final Uint8List memberToken; // 32B
  final Uint8List ikPub;
  final Uint8List lkPub;
  const MemberRecord({
    required this.memberToken,
    required this.ikPub,
    required this.lkPub,
  });
}

typedef MemberFetcher = Future<List<MemberRecord>> Function(Uint8List albumId);

class MemberDirectory {
  final MemberFetcher _fetch;
  // hex(albumId) -> hex(token) -> pubs
  final Map<String, Map<String, MemberPubs>> _cache = {};

  MemberDirectory(this._fetch);

  // Returns null when no member with this token : sender no longer in the
  // member list. Caller bails (spec §7.1) -> these specs are actually my impl plans.
  Future<MemberPubs?> lookup(Uint8List albumId, Uint8List memberToken) async {
    final aHex = _hex(albumId);
    final tHex = _hex(memberToken);
    final cached = _cache[aHex]?[tHex];
    if (cached != null) return cached;
    final list = await _fetch(albumId);
    // Rebuild the album's slice from the fresh roster so tokens no longer
    // returned (a removed member) fall out of the cache rather than lingering
    final albumCache = <String, MemberPubs>{};
    for (final m in list) {
      albumCache[_hex(m.memberToken)] =
          MemberPubs(ikPub: m.ikPub, lkPub: m.lkPub);
    }
    _cache[aHex] = albumCache;
    return albumCache[tHex];
  }

  // Evicts one member from the cache : the member_revoked flow calls this so the
  // next lookup of that token re fetches and sees it gone. No op if not cached
  void drop(Uint8List albumId, Uint8List memberToken) {
    _cache[_hex(albumId)]?.remove(_hex(memberToken));
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
