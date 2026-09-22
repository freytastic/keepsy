import 'dart:async';

import 'package:keepsy/data/models/album_model.dart';

// Serializes authoritative shelf comparisons and coalesces realtime bursts
class ActivitySync {
  final Future<void> Function(List<AlbumModel> albums) _observe;
  final Future<void> Function() _afterEach;
  // Read merged app state so stale HTTP responses cannot undo realtime changes
  final List<AlbumModel> Function() _current;
  final Duration _quiet;

  // Incomplete local restores could look like departures
  // Only server listings make the shelf authoritative
  bool _trusted = false;
  bool _stopped = false;
  Timer? _timer;
  Future<void>? _running;
  bool _again = false;
  final Set<Future<void>> _alarms = {};

  ActivitySync({
    required Future<void> Function(List<AlbumModel> albums) observe,
    required Future<void> Function() afterEach,
    required List<AlbumModel> Function() current,
    Duration quiet = const Duration(seconds: 15),
  })  : _observe = observe,
        _afterEach = afterEach,
        _current = current,
        _quiet = quiet;

  Future<void> listed() {
    if (_stopped) return Future.value();
    _trusted = true;
    _timer?.cancel();
    return _enqueue();
  }

  void nudge() {
    if (_stopped || !_trusted) return;
    _timer?.cancel();
    _timer = Timer(_quiet, () => unawaited(flush()));
  }

  // Track pin alarms so Activity reads and terminal wipe wait for their writes
  // They need no listing because they originate from this phone's pins
  Future<void> alarm(Future<void> Function() write) async {
    if (_stopped) return;
    final f = write().catchError((_) {});
    _alarms.add(f);
    try {
      await f;
    } finally {
      _alarms.remove(f);
    }
  }

  Future<void> _alarmsSettled() => Future.wait(_alarms.toList());

  // Flush immediately when Activity opens, after any alarm still being written
  Future<void> flush() async {
    await _alarmsSettled();
    if (_stopped || !_trusted) return;
    _timer?.cancel();
    return _enqueue();
  }

  // Terminal wipe waits for active comparison writes before clearing the store
  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    await _alarmsSettled();
    final running = _running;
    if (running != null) await running;
  }

  // One comparison at a time, each reading the snapshot the last one wrote
  // Requests landing mid run collapse into one follow up over the newest shelf
  Future<void> _enqueue() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _drain();
  }

  Future<void> _drain() async {
    try {
      do {
        _again = false;
        if (_stopped) return;
        try {
          await _observe(List.unmodifiable(_current()));
          await _afterEach();
        } catch (_) {
          // Activity is a record of what happened, never a reason to fail
        }
      } while (_again);
    } finally {
      _running = null;
    }
  }
}
