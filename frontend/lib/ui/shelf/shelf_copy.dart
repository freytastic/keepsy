class ShelfEntry {
  final String id;
  final String? title;
  final int unseen;
  final DateTime? lastActivity;

  const ShelfEntry({
    required this.id,
    required this.title,
    required this.unseen,
    required this.lastActivity,
  });
}

class Headline {
  final String title;
  final String sub;

  const Headline(this.title, this.sub);
}

const _words = [
  'No',
  'One',
  'Two',
  'Three',
  'Four',
  'Five',
  'Six',
  'Seven',
  'Eight',
  'Nine',
  'Ten',
  'Eleven',
  'Twelve',
];

String spell(int n) => n >= 0 && n < _words.length ? _words[n] : '$n';

Headline headlineFor(List<ShelfEntry> entries) {
  if (entries.isEmpty) {
    return const Headline(
      'No albums yet.',
      'Make one and invite the people who were there.',
    );
  }

  final waiting = entries.where((e) => e.unseen > 0).toList();
  final frames = waiting.fold(0, (n, e) => n + e.unseen);

  if (frames > 0) {
    final title = '${spell(frames)} new frame${frames > 1 ? 's' : ''}.';
    final named = waiting.where((e) => e.title != null).toList();
    if (named.isEmpty) return Headline(title, '');

    final others = named.length - 1;
    final where = others == 0
        ? named.first.title!
        : '${named.first.title} and ${spell(others).toLowerCase()} '
            'other${others > 1 ? 's' : ''}';
    return Headline(title, 'in $where.');
  }

  final albums =
      '${spell(entries.length)} album${entries.length > 1 ? 's' : ''}.';

  // Server order is authoritative because activity timestamps are hour truncated
  final recent = entries.first;
  if (recent.title == null) return Headline(albums, '');
  return Headline(albums, '${recent.title}, most recently.');
}

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String? relativeTime(DateTime? when, {DateTime? now}) {
  if (when == null) return null;
  // Convert UTC before comparing calendar days
  final at = when.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final days = DateTime(today.year, today.month, today.day)
      .difference(DateTime(at.year, at.month, at.day))
      .inDays;

  if (days <= 0) return 'today';
  if (days == 1) return 'yesterday';
  if (days < 7) return '$days days ago';
  if (days < 14) return 'last week';
  final month = _months[at.month - 1];
  return at.year == today.year ? 'in $month' : 'in $month ${at.year}';
}

int unseenCount({
  required int generation,
  required int lastSeen,
  required int mediaCount,
}) {
  final raw = generation - lastSeen;
  if (raw <= 0) return 0;
  // The monotonic counter can exceed mediaCount after deletions
  return raw > mediaCount ? mediaCount : raw;
}
