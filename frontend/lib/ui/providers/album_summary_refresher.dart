import 'package:keepsy/data/models/album_model.dart';

// Serializes refreshes so a later failure cannot hide an earlier success
class AlbumSummaryRefresher {
  final Future<List<AlbumModel>?> Function() _fetch;
  final void Function(List<AlbumModel>) _apply;
  Future<void>? _inFlight;
  bool _again = false;

  AlbumSummaryRefresher({
    required Future<List<AlbumModel>?> Function() fetch,
    required void Function(List<AlbumModel>) apply,
  })  : _fetch = fetch,
        _apply = apply;

  // Coalesces overlapping requests into one follow-up
  Future<void> refresh() {
    final running = _inFlight;
    if (running != null) {
      _again = true;
      return running;
    }
    return _inFlight = _drain();
  }

  Future<void> _drain() async {
    try {
      do {
        _again = false;
        try {
          final fresh = await _fetch();
          if (fresh != null) _apply(fresh);
        } catch (_) {}
      } while (_again);
    } finally {
      _inFlight = null;
    }
  }
}
