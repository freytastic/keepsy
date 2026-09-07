import 'dart:async';

import 'package:keepsy/diagnostics/trace.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';
import 'package:uuid/uuid.dart';

import 'rate_estimator.dart';
import 'upload_item.dart';
import 'upload_ports.dart';
import 'upload_snapshot.dart';

const int _kDefaultTransferAttempts = 3;
const int _kDefaultPresignRefreshes = 2;
const int _kDefaultPrepareAttempts = 2;

Duration _defaultBackoff(int attempt) => Duration(milliseconds: 400 * attempt);

// Serial queue that limits preparation and transfer memory to one item
class UploadCoordinator {
  final PickedSourceStore _sources;
  final MediaPreparer _preparer;
  final StagedUploader _uploader;
  final UploadSink _sink;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _sleep;
  final Duration Function(int) _backoff;
  final Duration throttle;
  final int transferAttempts;
  final int presignRefreshes;
  final int prepareAttempts;

  final List<UploadItem> _items = [];
  final Map<String, PauseReason> _paused = {};
  final Map<String, DateTime> _startedAt = {};
  final Map<String, EtaEstimator> _batchEta = {};
  // Wait before reserving again because abort uses only album and media ID
  final Map<String, Future<void>> _pendingAborts = {};
  final Map<String, int> _batchGeneration = {};
  final Map<String, Map<String, String>> _mimeTypes = {};
  final RateEstimator _rate = RateEstimator();
  final StreamController<UploadState> _out =
      StreamController<UploadState>.broadcast();

  CancelToken? _activeCancel;
  String? _activeItemId;
  Future<void>? _activeRun;
  bool _pumping = false;
  Timer? _throttleTimer;
  bool _closed = false;

  UploadCoordinator({
    required PickedSourceStore sources,
    required MediaPreparer preparer,
    required StagedUploader uploader,
    required UploadSink sink,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
    Duration Function(int)? backoff,
    this.throttle = const Duration(milliseconds: 100),
    this.transferAttempts = _kDefaultTransferAttempts,
    this.presignRefreshes = _kDefaultPresignRefreshes,
    this.prepareAttempts = _kDefaultPrepareAttempts,
  })  : _sources = sources,
        _preparer = preparer,
        _uploader = uploader,
        _sink = sink,
        _now = now ?? DateTime.now,
        _sleep = sleep ?? Future<void>.delayed,
        _backoff = backoff ?? _defaultBackoff;

  Stream<UploadState> get stream => _out.stream;
  UploadState get state => _buildState();

  String enqueue({
    required String albumId,
    required List<PickedSource> sources,
  }) {
    final batchId = const Uuid().v4();
    for (final s in sources) {
      _items.add(UploadItem(
        id: const Uuid().v4(),
        batchId: batchId,
        albumId: albumId,
        mediaId: MediaId.fresh(),
        sourcePath: s.path,
      ));
    }
    _mimeTypes[batchId] = {
      for (final s in sources) s.path: s.mimeType,
    };
    _batchEta[batchId] = EtaEstimator();
    _rate.reset();
    _emitNow();
    unawaited(_pump());
    return batchId;
  }

  // Moves picks into managed staging before enqueue
  Future<List<PickedSource>> stage(List<PickedSource> sources) async => [
        for (final s in sources)
          PickedSource(path: await _sources.adopt(s.path), mimeType: s.mimeType)
      ];

  // Removes plaintext picker copies that were not enqueued
  Future<void> discardUnused(Iterable<String> paths) async {
    for (final path in paths) {
      await _discard(path);
    }
  }

  // Called after a successful album key install
  void resumeAlbum(String albumId) {
    if (_paused.remove(albumId) == null) return;
    _emitNow();
    unawaited(_pump());
  }

  void retry(String itemId) {
    final i = _indexOf(itemId);
    if (i < 0) return;
    final item = _items[i];
    if (item.phase != UploadPhase.failed) return;
    if (!(item.failure?.retryable ?? false)) return;
    _items[i] = item.copyWith(
      phase: UploadPhase.queued,
      manualRetries: item.manualRetries + 1,
      transferAttempt: 0,
      logicalBytesSent: 0,
    );
    _emitNow();
    unawaited(_pump());
  }

  void retryFailed(String batchId) {
    for (final item in [..._items]) {
      if (item.batchId == batchId && item.phase == UploadPhase.failed) {
        retry(item.id);
      }
    }
  }

  Future<void> cancelBatch(String batchId) async {
    final doomed = _items.where((i) => i.batchId == batchId).toList();
    for (final item in doomed) {
      await _removeItem(item, emit: false);
    }
    _emitNow();
  }

  // Abandoning retryable items must discard their picked files
  Future<void> removeFailed(String batchId) async {
    final doomed = _items
        .where((i) => i.batchId == batchId && i.phase == UploadPhase.failed)
        .toList();
    for (final item in doomed) {
      await _removeItem(item, emit: false);
    }
    _emitNow();
  }

  Future<void> removeItem(String itemId) async {
    final i = _indexOf(itemId);
    if (i < 0) return;
    await _removeItem(_items[i], emit: true);
  }

  // Removes only settled batches and any retained sources
  Future<void> dismissBatch(String batchId) async {
    if (_items.any((i) => i.batchId == batchId && !i.isFinished)) return;
    final dropped = _items.where((i) => i.batchId == batchId).toList();
    _items.removeWhere((i) => i.batchId == batchId);
    _batchEta.remove(batchId);
    _batchGeneration.remove(batchId);
    _mimeTypes.remove(batchId);
    _emitNow();
    for (final item in dropped) {
      await _settleAbort(item.id);
      if (!item.sourceDiscarded) await _discard(item.sourcePath);
    }
  }

  Future<void> dispose() async {
    _closed = true;
    _throttleTimer?.cancel();
    _activeCancel?.cancel();
    await _out.close();
  }

  Future<void> _removeItem(UploadItem item, {required bool emit}) async {
    if (item.id == _activeItemId) {
      if (_byId(item.id)?.phase == UploadPhase.confirming) {
        // Confirmation cannot be canceled, so wait before removal
        await _activeRun;
      } else {
        _set(item.id, phase: UploadPhase.canceling);
        _activeCancel?.cancel();
        _beginAbort(item);
      }
    }
    // Wait before forgetting the media ID
    await _settleAbort(item.id);
    if (!item.sourceDiscarded) {
      await _discard(item.sourcePath);
    }
    _items.removeWhere((i) => i.id == item.id);
    _forgetEmptyBatch(item.batchId);
    _releaseEmptyAlbum(item.albumId);
    if (emit) _emitNow();
  }

  void _forgetEmptyBatch(String batchId) {
    if (_items.any((i) => i.batchId == batchId)) return;
    _batchEta.remove(batchId);
    _batchGeneration.remove(batchId);
    _mimeTypes.remove(batchId);
  }

  // Clear pauses after the album queue empties
  void _releaseEmptyAlbum(String albumId) {
    if (_items.any((i) => i.albumId == albumId)) return;
    _paused.remove(albumId);
  }

  int _indexOf(String itemId) => _items.indexWhere((i) => i.id == itemId);

  UploadItem? _byId(String itemId) {
    final i = _indexOf(itemId);
    return i < 0 ? null : _items[i];
  }

  void _set(
    String itemId, {
    UploadPhase? phase,
    int? payloadByteLength,
    int? logicalBytesSent,
    int? transferAttempt,
    int? prepareAttempt,
    UploadFailure? failure,
    bool clearFailure = false,
    bool? sourceDiscarded,
  }) {
    final i = _indexOf(itemId);
    if (i < 0) return;
    _items[i] = _items[i].copyWith(
      phase: phase,
      payloadByteLength: payloadByteLength,
      logicalBytesSent: logicalBytesSent,
      transferAttempt: transferAttempt,
      prepareAttempt: prepareAttempt,
      failure: failure,
      clearFailure: clearFailure,
      sourceDiscarded: sourceDiscarded,
    );
  }

  UploadItem? _nextRunnable() {
    for (final item in _items) {
      if (item.phase != UploadPhase.queued) continue;
      if (_paused.containsKey(item.albumId)) continue;
      return item;
    }
    return null;
  }

  Future<void> _pump() async {
    if (_pumping || _closed) return;
    _pumping = true;
    try {
      while (!_closed) {
        final item = _nextRunnable();
        if (item == null) break;
        final run = _runItem(item);
        _activeRun = run;
        try {
          await run;
        } finally {
          _activeRun = null;
        }
        _settleBatchIfDone(item.batchId, item.albumId);
      }
    } finally {
      _pumping = false;
      _activeItemId = null;
      _activeCancel = null;
      _emitNow();
    }
  }

  void _settleBatchIfDone(String batchId, String albumId) {
    final live = _items.where((i) => i.batchId == batchId);
    if (live.isEmpty || live.any((i) => !i.isFinished)) return;
    if (live.any((i) => i.phase == UploadPhase.done)) {
      unawaited(_guard(() => _sink.onBatchSettled(albumId)));
    }
  }

  Future<void> _runItem(UploadItem start) async {
    final cancel = CancelToken();
    _activeCancel = cancel;
    _activeItemId = start.id;
    _startedAt[start.id] = _now();
    final span = Trace.start('upload.item', fields: {
      'album': Trace.id(start.albumId),
      'media': Trace.id(start.mediaId.value),
      'retry': start.manualRetries,
    });
    var wireBytes = 0;

    try {
      if (start.failure?.resumeFrom == ResumePoint.confirm) {
        _set(start.id, phase: UploadPhase.confirming, clearFailure: true);
        _emitNow();
        _recordGeneration(start.batchId,
            await _uploader.confirm(start.albumId, start.mediaId));
        await _finishDone(start.id, envelope: null);
        span.end(fields: {'stage': 'confirm_only'});
        return;
      }

      _set(start.id,
          phase: UploadPhase.preparing,
          clearFailure: true,
          logicalBytesSent: 0);
      _emitNow();

      final plaintext = await _sources.read(start.sourcePath);
      final mime = _mimeTypes[start.batchId]?[start.sourcePath] ?? 'image/jpeg';
      final env = await _preparer.prepare(
        albumId: start.albumId,
        mediaId: start.mediaId,
        plaintext: plaintext,
        mimeType: mime,
      );
      // Preparation cannot be canceled
      if (cancel.isCancelled || _byId(start.id) == null) return;
      _sink.onPrepared(start.albumId, start.mediaId, env.thumbPlaintext);
      final payload = env.blobSize + env.thumbSize;
      _set(start.id, phase: UploadPhase.reserving, payloadByteLength: payload);
      _emitNow();

      await _settleAbort(start.id);
      var reservation = await _uploader.reserve(start.albumId, env);
      // Reserve may finish after cancellation and create a row to abort
      if (cancel.isCancelled) {
        await _guard(() => _uploader.abort(start.albumId, start.mediaId));
        return;
      }

      _set(start.id, phase: UploadPhase.sendingFile);
      _emitNow();
      reservation = await _send(
        item: start,
        env: env,
        reservation: reservation,
        base: 0,
        cancel: cancel,
        onWire: (n) => wireBytes += n,
        put: (r, sink) => _uploader.putFile(start.albumId, r, env,
            onBytes: sink, cancel: cancel),
      );

      if (env.hasThumb && reservation.thumbUploadUrl != null) {
        _set(start.id, phase: UploadPhase.sendingThumb);
        _emitNow();
        reservation = await _send(
          item: start,
          env: env,
          reservation: reservation,
          base: env.blobSize,
          cancel: cancel,
          onWire: (n) => wireBytes += n,
          put: (r, sink) => _uploader.putThumb(start.albumId, r, env,
              onBytes: sink, cancel: cancel),
        );
      }

      if (cancel.isCancelled) return;
      _set(start.id, phase: UploadPhase.confirming, logicalBytesSent: payload);
      _emitNow();
      _recordGeneration(
          start.batchId, await _uploader.confirm(start.albumId, start.mediaId));
      await _finishDone(start.id, envelope: env);
      span.end(fields: {'bytes': payload, 'wire': wireBytes});
    } catch (error) {
      if (cancel.isCancelled) {
        span.fail('cancelled');
        return;
      }
      final failure = _classify(error, _byId(start.id)?.phase);
      span.fail(failure.code, fields: {'wire': wireBytes});
      await _park(start.id, failure);
    } finally {
      _startedAt.remove(start.id);
    }
  }

  // Retries one asset without rewinding a completed file slice
  Future<Reservation> _send({
    required UploadItem item,
    required UploadEnvelope env,
    required Reservation reservation,
    required int base,
    required CancelToken cancel,
    required void Function(int) onWire,
    required Future<void> Function(Reservation, ProgressSink) put,
  }) async {
    var current = reservation;
    var refreshes = 0;
    var lastSeen = 0;

    for (var attempt = 1;; attempt++) {
      if (attempt > 1) _rate.reset();
      lastSeen = 0;
      _set(item.id, logicalBytesSent: base, transferAttempt: attempt);
      _emitThrottled();
      try {
        await put(current, (soFar) {
          final delta = soFar - lastSeen;
          lastSeen = soFar;
          if (delta > 0) {
            onWire(delta);
            _rate.add(delta, _now());
          }
          _set(item.id, logicalBytesSent: base + soFar);
          _emitThrottled();
        });
        return current;
      } catch (error) {
        if (cancel.isCancelled) rethrow;
        final kind = _kindOf(error);
        if (kind == UploadFailureKind.presignExpired &&
            refreshes < presignRefreshes) {
          refreshes++;
          current = await _uploader.reserve(item.albumId, env);
          continue;
        }
        if (attempt >= transferAttempts || !_autoRetryable(kind)) rethrow;
        await _sleep(_backoff(attempt));
      }
    }
  }

  Future<void> _finishDone(String itemId, {UploadEnvelope? envelope}) async {
    final item = _byId(itemId);
    if (item == null) return;
    // Cache seeding is best effort after confirmation
    if (envelope != null) {
      await _guard(() => _sink.seed(item.albumId, envelope));
    }
    await _discard(item.sourcePath);
    final payload = item.payloadByteLength ?? 0;
    final startedAt = _startedAt[itemId];
    if (startedAt != null) {
      _batchEta[item.batchId]?.addCompleted(_now().difference(startedAt));
    }
    _set(itemId,
        phase: UploadPhase.done,
        logicalBytesSent: payload,
        sourceDiscarded: true,
        clearFailure: true);
    _emitNow();
  }

  Future<void> _park(String itemId, UploadFailure failure) async {
    final item = _byId(itemId);
    if (item == null) return;

    if (pausesAlbum(failure.kind)) {
      _paused[item.albumId] = failure.kind == UploadFailureKind.rotationPending
          ? PauseReason.rotationPending
          : PauseReason.noAlbumKey;
      _set(itemId, phase: UploadPhase.queued, clearFailure: true);
      _emitNow();
      return;
    }

    // Reprepare with the same media ID under the newest album key
    if (failure.kind == UploadFailureKind.epochStale &&
        item.prepareAttempt < prepareAttempts) {
      _beginAbort(item);
      _set(itemId,
          phase: UploadPhase.queued,
          prepareAttempt: item.prepareAttempt + 1,
          logicalBytesSent: 0,
          clearFailure: true);
      _emitNow();
      return;
    }

    if (isTerminal(failure.kind)) {
      await _discard(item.sourcePath);
      _set(itemId,
          phase: UploadPhase.failed, failure: failure, sourceDiscarded: true);
      _emitNow();
      return;
    }

    // Manual retry reprepares after the prior abort settles
    if (failure.resumeFrom == ResumePoint.prepare) {
      _beginAbort(item);
    }
    _set(itemId, phase: UploadPhase.failed, failure: failure);
    _emitNow();
  }

  // Prevents a retry from racing its own reservation cleanup
  Future<void> _settleAbort(String itemId) async {
    final pending = _pendingAborts.remove(itemId);
    if (pending != null) await pending;
  }

  void _beginAbort(UploadItem item) {
    _pendingAborts[item.id] =
        _guard(() => _uploader.abort(item.albumId, item.mediaId));
  }

  Future<void> _discard(String path) => _guard(() => _sources.discard(path));

  Future<void> _guard(Future<void> Function() body) async {
    try {
      await body();
    } catch (_) {}
  }

  UploadFailureKind _kindOf(Object error) =>
      error is UploadStageException ? error.kind : UploadFailureKind.unknown;

  bool _autoRetryable(UploadFailureKind kind) =>
      kind == UploadFailureKind.transport ||
      kind == UploadFailureKind.server ||
      kind == UploadFailureKind.presignExpired;

  UploadFailure _classify(Object error, UploadPhase? phase) {
    final kind = _kindOf(error);
    final code = error is UploadStageException ? error.code : 'unknown';
    // Retry confirm only when the server result is ambiguous
    final ambiguousConfirm = phase == UploadPhase.confirming &&
        (kind == UploadFailureKind.transport ||
            kind == UploadFailureKind.server);
    return UploadFailure(
      kind: kind,
      resumeFrom: ambiguousConfirm ? ResumePoint.confirm : ResumePoint.prepare,
      code: code,
    );
  }

  void _emitNow() {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _publish();
  }

  // Throttle byte progress only
  void _emitThrottled() {
    if (_throttleTimer != null) return;
    _throttleTimer = Timer(throttle, () {
      _throttleTimer = null;
      _publish();
    });
  }

  void _publish() {
    if (_closed || _out.isClosed) return;
    _out.add(_buildState());
  }

  UploadState _buildState() {
    // Map iteration follows insertion order, so batches stay in enqueue order
    final byBatch = <String, List<UploadItem>>{};
    for (final item in _items) {
      (byBatch[item.batchId] ??= <UploadItem>[]).add(item);
    }
    final now = _now();
    final snapshots = <UploadBatchSnapshot>[];
    for (final batchId in byBatch.keys) {
      final items = byBatch[batchId]!;
      final albumId = items.first.albumId;
      final active = items.where((i) => !i.isFinished).toList();
      // Only the running batch owns speed and ETA
      final running = items.any((i) => i.id == _activeItemId);
      // Hide retained speed outside active transfers
      final onWire = items.any((i) => i.id == _activeItemId && i.isSending);
      final activeElapsed = running
          ? now.difference(_startedAt[_activeItemId!] ?? now)
          : Duration.zero;
      final paused = _paused[albumId];
      snapshots.add(UploadBatchSnapshot(
        batchId: batchId,
        albumId: albumId,
        items: [for (final i in items) _view(i)],
        doneCount: items.where((i) => i.phase == UploadPhase.done).length,
        failedCount: items.where((i) => i.phase == UploadPhase.failed).length,
        unprocessableCount: items
            .where((i) => i.failure?.kind == UploadFailureKind.unprocessable)
            .length,
        logicalBytesSent: _sentBytes(items),
        bytesPerSecond: onWire ? _rate.bytesPerSecond(now) : null,
        eta: running
            ? _batchEta[batchId]?.estimate(
                remaining: active.length,
                activeElapsed: activeElapsed,
              )
            : null,
        paused: paused,
        mediaGeneration: _batchGeneration[batchId] ?? 0,
      ));
    }
    return UploadState(snapshots);
  }

  // Ignore confirmations for batches removed while awaiting the server
  void _recordGeneration(String batchId, int generation) {
    if (!_items.any((i) => i.batchId == batchId)) return;
    final seen = _batchGeneration[batchId] ?? 0;
    if (generation > seen) _batchGeneration[batchId] = generation;
  }

  int _sentBytes(List<UploadItem> items) =>
      items.fold<int>(0, (sum, i) => sum + i.logicalBytesSent);

  UploadItemView _view(UploadItem i) {
    final payload = i.payloadByteLength ?? 0;
    final fraction = i.phase == UploadPhase.done
        ? 1.0
        : payload <= 0
            ? 0.0
            : (i.logicalBytesSent / payload).clamp(0.0, 1.0);
    return UploadItemView(
      id: i.id,
      mediaId: i.mediaId,
      sourcePath: i.sourceDiscarded ? null : i.sourcePath,
      phase: i.phase,
      fraction: fraction,
      failure: i.failure,
    );
  }
}
