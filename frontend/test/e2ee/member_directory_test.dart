import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/member_directory.dart';

Uint8List _album([int s = 0xA1]) => Uint8List.fromList(List<int>.filled(16, s));
Uint8List _tok(int s) => Uint8List.fromList(List<int>.filled(32, s));

MemberRecord _rec(int s) =>
    MemberRecord(memberToken: _tok(s), ikPub: _tok(s), lkPub: _tok(s));

void main() {
  test('drop evicts a token so the next lookup re-fetches the roster',
      () async {
    var fetches = 0;
    var roster = [_rec(1), _rec(2)];
    final dir = MemberDirectory((album) async {
      fetches++;
      return roster;
    });

    // first lookup populates the cache for the whole album (1 fetch)
    expect(await dir.lookup(_album(), _tok(1)), isNotNull);
    expect(fetches, 1);
    // cached: no second fetch
    expect(await dir.lookup(_album(), _tok(2)), isNotNull);
    expect(fetches, 1);

    // member 2 is removed on the server, drop its cached entry
    dir.drop(_album(), _tok(2));
    roster = [_rec(1)]; // server now returns the reduced roster

    // looking up the dropped token re fetches and finds it gone
    expect(await dir.lookup(_album(), _tok(2)), isNull);
    expect(fetches, 2);
  });
}
