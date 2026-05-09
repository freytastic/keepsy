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
    final albumCache = _cache.putIfAbsent(aHex, () => {});
    // TODO(§7.x): on member removal, removed tokens stay in albumCache until a
    // restart : benign here since installVerified rejects replayed wraps from a
    // former admin via the monotone+sparse rule, but the removal flow PR should
    // diff against 'list' and drop entries whose token isn't returned anymore
    for (final m in list) {
      albumCache[_hex(m.memberToken)] =
          MemberPubs(ikPub: m.ikPub, lkPub: m.lkPub);
    }
    return albumCache[tHex];
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
