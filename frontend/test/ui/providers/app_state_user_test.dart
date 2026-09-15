import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/providers/app_state.dart';

void main() {
  test('the account is announced from the cache and from the server', () {
    final seen = <String>[];
    final s = AppState()..attachUserKnown(seen.add);

    s.setCachedUserId('u1');
    s.setUserData({'id': 'u1', 'keepsy_id': 'K1'});

    expect(seen, ['u1', 'u1']);
    expect(s.userId, 'u1');
  });

  test('a cached id never overrides the server account', () {
    final seen = <String>[];
    final s = AppState()..attachUserKnown(seen.add);
    s.setUserData({'id': 'server'});

    s.setCachedUserId('stale');

    expect(s.userId, 'server');
    expect(seen, ['server']);
  });

  test('a listing without an id announces nothing', () {
    final seen = <String>[];
    AppState()
      ..attachUserKnown(seen.add)
      ..setUserData({'keepsy_id': 'K1'});
    expect(seen, isEmpty);
  });
}
