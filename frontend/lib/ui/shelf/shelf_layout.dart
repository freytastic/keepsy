import 'package:keepsy/ui/shelf/album_print.dart';

enum ShelfView { stacked, compact }

class ShelfSlot<T> {
  final T album;
  final PrintSize size;

  const ShelfSlot(this.album, this.size);
}

List<ShelfSlot<T>> planFor<T>(List<T> albums, ShelfView view) {
  if (view == ShelfView.stacked || albums.isEmpty) {
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

// Never shrink the lead print past this, even if the pair below it must scroll
const double minLeadScale = 0.84;

// Scales the lead print in compact view just enough that the pair below it,
// names included, ends above the bottom bar. Taller screens keep full size
double leadScale({
  required double viewHeight,
  required double above,
  required double leadHeight,
  required double below,
}) {
  if (leadHeight <= 0) return 1;
  final room = viewHeight - above - below;
  return (room / leadHeight).clamp(minLeadScale, 1.0);
}
