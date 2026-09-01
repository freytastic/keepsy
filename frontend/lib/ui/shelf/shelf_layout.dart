import 'package:keepsy/ui/shelf/album_print.dart';

enum ShelfView { rows, bento }

class ShelfSlot<T> {
  final T album;
  final PrintSize size;

  const ShelfSlot(this.album, this.size);
}

List<ShelfSlot<T>> planFor<T>(List<T> albums, ShelfView view) {
  if (view == ShelfView.rows || albums.isEmpty) {
    return [for (final a in albums) ShelfSlot(a, PrintSize.large)];
  }

  final slots = <ShelfSlot<T>>[ShelfSlot(albums.first, PrintSize.large)];
  final rest = albums.sublist(1);
  for (var i = 0; i < rest.length; i += 2) {
    final lone = i == rest.length - 1;
    slots.add(ShelfSlot(rest[i], lone ? PrintSize.large : PrintSize.small));
    if (!lone) slots.add(ShelfSlot(rest[i + 1], PrintSize.small));
  }
  return slots;
}
