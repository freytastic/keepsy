import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/shelf/print_style.dart';
import 'package:keepsy/ui/shelf/shelf_copy.dart';

ShelfEntry _entry({
  required String id,
  String? title,
  int unseen = 0,
}) =>
    ShelfEntry(
      id: id,
      title: title,
      unseen: unseen,
      lastActivity: DateTime(2026, 8, 1),
    );

void main() {
  test('stable card hashing matches the FNV-1a vectors', () {
    expect(fnv1a32(''), 0x811c9dc5);
    expect(fnv1a32('a'), 0xe40c292c);
  });

  test('headline trusts server order instead of quantized timestamps', () {
    final headline = headlineFor([
      _entry(id: 'confirmed-latest', title: 'Trip'),
      _entry(id: 'same-hour', title: 'Birthday'),
    ]);

    expect(headline.sub, 'Trip, most recently.');
  });

  test('unresolved encrypted titles never leak into the headline', () {
    final headline = headlineFor([_entry(id: 'opaque', unseen: 3)]);

    expect(headline.title, 'Three new frames.');
    expect(headline.sub, isEmpty);
  });

  test('unseen count clamps historical generations after deletion', () {
    expect(unseenCount(generation: 12, lastSeen: 2, mediaCount: 4), 4);
    expect(unseenCount(generation: 8, lastSeen: 9, mediaCount: 4), 0);
  });

  test('relative time follows calendar days', () {
    final now = DateTime(2026, 9, 1, 0, 5);

    expect(relativeTime(DateTime(2026, 8, 31, 23, 55), now: now), 'yesterday');
    expect(relativeTime(DateTime(2026, 8, 24), now: now), 'last week');
  });
}
