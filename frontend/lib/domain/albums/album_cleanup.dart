import 'dart:async';

enum AlbumPresence { member, gone, unknown }

typedef CleanupRecord = ({bool confirmed, int version});

abstract class AlbumCleanupStore {
  // Maps each album to deletion confirmation and record version
  Future<Map<String, CleanupRecord>> pending();
  // Every report bumps the version and confirmation never downgrades
  Future<void> put(String albumId, {required bool confirmed});
  // Prevents an old probe or wipe from deleting a newer report
  Future<void> removeIfUnchanged(String albumId, int version);
}

// Persists cleanup until a verified wipe finishes
class AlbumCleanupQueue {
  final AlbumCleanupStore _store;
  final Future<AlbumPresence> Function(String albumId) _probe;
  // Must throw when anything could not be removed
  final Future<void> Function(String albumId) _wipe;
  final Timer Function(Duration, void Function()) _timer;

  Future<void>? _running;
  bool _again = false;
  bool _closed = false;
  int _failures = 0;
  Timer? _retry;

  AlbumCleanupQueue({
    required AlbumCleanupStore store,
    required Future<AlbumPresence> Function(String albumId) probe,
    required Future<void> Function(String albumId) wipe,
    Timer Function(Duration, void Function())? timer,
  })  : _store = store,
        _probe = probe,
        _wipe = wipe,
        _timer = timer ?? Timer.new;

  Future<void> albumGone(String albumId) => _enqueue(albumId, confirmed: true);

  // A listing left it out, which a listing raced by a new album can also do
  Future<void> albumMissing(String albumId) =>
      _enqueue(albumId, confirmed: false);

  Future<void> _enqueue(String albumId, {required bool confirmed}) async {
    if (_closed) return;
    await _store.put(albumId, confirmed: confirmed);
    unawaited(drain());
  }

  Future<void> drain() {
    if (_closed) return Future.value();
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    // Block body : returning the removed future would make drain await itself
    final run = _drainAll().whenComplete(() {
      _running = null;
    });
    _running = run;
    return run;
  }

  Future<void> _drainAll() async {
    var remaining = 0;
    do {
      _again = false;
      remaining = 0;
      final pending = await _store.pending();
      for (final entry in pending.entries) {
        if (_closed) return;
        if (!await _settle(entry.key, entry.value)) remaining++;
      }
    } while (_again && !_closed);
    if (remaining == 0 && (await _store.pending()).isNotEmpty) remaining = 1;
    _schedule(remaining);
  }

  Future<bool> _settle(String albumId, CleanupRecord record) async {
    try {
      if (!record.confirmed) {
        switch (await _probe(albumId)) {
          case AlbumPresence.member:
            await _store.removeIfUnchanged(albumId, record.version);
            return true;
          case AlbumPresence.unknown:
            return false;
          case AlbumPresence.gone:
            break;
        }
      }
      await _wipe(albumId);
      // A report that arrived during the wipe keeps its record for another pass
      await _store.removeIfUnchanged(albumId, record.version);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _schedule(int remaining) {
    _retry?.cancel();
    _retry = null;
    if (remaining == 0 || _closed) {
      _failures = 0;
      return;
    }
    _failures++;
    final seconds = 15 * (1 << (_failures - 1).clamp(0, 5));
    _retry = _timer(Duration(seconds: seconds), () => unawaited(drain()));
  }

  Future<void> shutdown() async {
    _closed = true;
    _retry?.cancel();
    try {
      await _running;
    } catch (_) {}
  }
}
