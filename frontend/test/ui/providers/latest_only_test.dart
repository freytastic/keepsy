import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/providers/latest_only.dart';

void main() {
  late LatestOnly guard;
  setUp(() => guard = LatestOnly());

  test('only the newest request is current', () {
    final first = guard.begin();
    final second = guard.begin();

    expect(guard.isCurrent(first), isFalse);
    expect(guard.isCurrent(second), isTrue);
  });

  test('an older success still applies when nothing newer has', () {
    final first = guard.begin();
    guard.begin();

    expect(guard.commit(first), isTrue,
        reason: 'a newer request that never applied must not discard this');
  });

  test('an older success cannot overwrite a newer one', () {
    final first = guard.begin();
    final second = guard.begin();

    expect(guard.commit(second), isTrue);
    expect(guard.commit(first), isFalse);
  });

  test('the same response cannot apply twice', () {
    final token = guard.begin();

    expect(guard.commit(token), isTrue);
    expect(guard.commit(token), isFalse);
  });
}
