import 'dart:async';
import 'dart:typed_data';

import 'epoch_rotator.dart' show IdentityMismatchException;
import 'expected_ik_resolver.dart' show MissingIdentityPinException;
import 'member_removal.dart' show IsRotationRequiredFn;
import 'prekey_bundle.dart' show BundleVerificationException;

typedef CanRotateFn = bool Function(Uint8List albumId);
typedef RecoverRotationFn = Future<bool> Function(Uint8List albumId);
typedef ReconcileAlbumFn = Future<void> Function(Uint8List albumId);

enum RotationPhase {
  clear,
  waiting,
  rotating,
  failed,
}

enum RotationFailure {
  identityUnconfirmed,
  unavailable,
}

class RotationStatus {
  final Uint8List albumId;
  final RotationPhase phase;
  final RotationFailure? failure;
  const RotationStatus({
    required this.albumId,
    required this.phase,
    this.failure,
  });
}

Duration _defaultBackoff(int attempt) =>
    attempt == 0 ? const Duration(seconds: 2) : const Duration(seconds: 10);

// Coalesces recovery triggers per album while the server keeps uploads frozen
class RotationRecoveryScheduler {
  final IsRotationRequiredFn _isRotationRequired;
  final CanRotateFn _canRotate;
  final RecoverRotationFn _recover;
  final ReconcileAlbumFn _reconcile;
  final Future<void> Function(Duration) _sleep;
  final Duration Function(int attempt) _backoff;
  final int maxAttempts;
  final int maxConcurrent;

  final Map<String, Future<void>> _inFlight = {};
  final Set<String> _again = {};
  final Map<String, RotationPhase> _owed = {};
  final StreamController<RotationStatus> _status =
      StreamController<RotationStatus>.broadcast();

  RotationRecoveryScheduler({
    required IsRotationRequiredFn isRotationRequired,
    required CanRotateFn canRotate,
    required RecoverRotationFn recover,
    required ReconcileAlbumFn reconcile,
    Future<void> Function(Duration)? sleep,
    Duration Function(int attempt)? backoff,
    this.maxAttempts = 3,
    this.maxConcurrent = 2,
  })  : _isRotationRequired = isRotationRequired,
        _canRotate = canRotate,
        _recover = recover,
        _reconcile = reconcile,
        _sleep = sleep ?? Future<void>.delayed,
        _backoff = backoff ?? _defaultBackoff;

  Stream<RotationStatus> get status => _status.stream;

  RotationPhase phaseOf(Uint8List albumId) =>
      _owed[_hex(albumId)] ?? RotationPhase.clear;

  // Fire and forget triggers never surface recovery failures
  Future<void> request(Uint8List albumId) {
    final key = _hex(albumId);
    final running = _inFlight[key];
    if (running != null) {
      _again.add(key);
      return running;
    }
    // Block body : returning the removed future would make run await itself
    final run = _drain(albumId, key).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = run;
    return run;
  }

  Future<void> checkAll(List<Uint8List> albumIds) async {
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < albumIds.length) {
        await request(albumIds[cursor++]);
      }
    }

    await Future.wait([
      for (var i = 0; i < maxConcurrent && i < albumIds.length; i++) worker(),
    ]);
  }

  // A newly installed epoch may be the rotation an owed album was waiting for
  void onEpochInstalled(Uint8List albumId) {
    if (_owed.containsKey(_hex(albumId))) unawaited(request(albumId));
  }

  void forget(Uint8List albumId) {
    final key = _hex(albumId);
    _owed.remove(key);
    _again.remove(key);
  }

  void dispose() => _status.close();

  Future<void> _drain(Uint8List albumId, String key) async {
    do {
      _again.remove(key);
      try {
        await _runOnce(albumId, key);
      } catch (_) {}
    } while (_again.contains(key));
  }

  Future<void> _runOnce(Uint8List albumId, String key) async {
    final bool required;
    try {
      required = await _isRotationRequired(albumId);
    } catch (_) {
      // Unknown while offline : keep the last known state
      return;
    }
    if (!required) {
      await _settle(albumId, key);
      return;
    }
    if (!_canRotate(albumId)) {
      _emit(albumId, key, RotationPhase.waiting);
      return;
    }
    for (var attempt = 0;; attempt++) {
      _emit(albumId, key, RotationPhase.rotating);
      try {
        await _recover(albumId);
        await _settle(albumId, key);
        return;
      } catch (e) {
        if (!_retryable(e) || attempt + 1 >= maxAttempts) {
          _emit(albumId, key, RotationPhase.failed, _failureOf(e));
          return;
        }
      }
      await _sleep(_backoff(attempt));
    }
  }

  // Clearing the debt is not enough : whoever won the race, this device still
  // has to install that epoch before its queued photos can go up
  Future<void> _settle(Uint8List albumId, String key) async {
    final wasOwed = _owed.containsKey(key);
    _emit(albumId, key, RotationPhase.clear);
    if (!wasOwed) return;
    try {
      await _reconcile(albumId);
    } catch (_) {}
  }

  void _emit(Uint8List albumId, String key, RotationPhase phase,
      [RotationFailure? failure]) {
    if (phase == RotationPhase.clear) {
      if (_owed.remove(key) == null) return;
    } else {
      _owed[key] = phase;
    }
    if (_status.isClosed) return;
    _status
        .add(RotationStatus(albumId: albumId, phase: phase, failure: failure));
  }
}

bool _retryable(Object e) => !(e is MissingIdentityPinException ||
    e is IdentityMismatchException ||
    e is BundleVerificationException ||
    e is StateError ||
    e is ArgumentError);

RotationFailure _failureOf(Object e) =>
    e is MissingIdentityPinException || e is IdentityMismatchException
        ? RotationFailure.identityUnconfirmed
        : RotationFailure.unavailable;

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
