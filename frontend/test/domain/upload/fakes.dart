import 'dart:async';
import 'dart:typed_data';

import 'package:keepsy/domain/upload/upload_item.dart';
import 'package:keepsy/domain/upload/upload_ports.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';

Uint8List _fill(int n, [int v = 7]) => Uint8List.fromList(List.filled(n, v));

UploadEnvelope envelopeFor(MediaId id,
    {int blob = 1000, int thumb = 100, int epoch = 3}) {
  return UploadEnvelope(
    mediaId: id.bytes,
    cipherBytes: _fill(blob),
    wrapNonce: _fill(12),
    wrapTagCT: _fill(48),
    epoch: epoch,
    blobSize: blob,
    blobSha256: _fill(32),
    mediaType: 'photo',
    mimeType: 'image/jpeg',
    filePlaintext: _fill(blob),
    thumbCipherBytes: thumb == 0 ? null : _fill(thumb),
    thumbWrapNonce: thumb == 0 ? null : _fill(12),
    thumbWrapTagCT: thumb == 0 ? null : _fill(48),
    thumbSha256: thumb == 0 ? null : _fill(32),
    thumbPlaintext: thumb == 0 ? null : _fill(thumb),
  );
}

class FakeSources implements PickedSourceStore {
  final Set<String> existing = {};
  final List<String> discarded = [];
  final Set<String> unreadable = {};
  void Function(String)? onDiscard;

  void add(String path) => existing.add(path);

  @override
  Future<Uint8List> read(String path) async {
    if (unreadable.contains(path) || !existing.contains(path)) {
      throw const UploadStageException(
          UploadFailureKind.sourceMissing, 'source_missing');
    }
    return _fill(64);
  }

  @override
  Future<void> discard(String path) async {
    onDiscard?.call(path);
    existing.remove(path);
    discarded.add(path);
  }
}

class FakePreparer implements MediaPreparer {
  int epoch = 3;
  int blob = 1000;
  int thumb = 100;
  final List<MediaId> prepared = [];
  UploadStageException? failWith;

  @override
  Future<int> latestEpoch(String albumId) async => epoch;

  @override
  Future<UploadEnvelope> prepare({
    required String albumId,
    required MediaId mediaId,
    required Uint8List plaintext,
    required String mimeType,
  }) async {
    final f = failWith;
    if (f != null) {
      failWith = null;
      throw f;
    }
    prepared.add(mediaId);
    return envelopeFor(mediaId, blob: blob, thumb: thumb, epoch: epoch);
  }
}

class FakeUploader implements StagedUploader {
  final List<String> calls = [];
  final List<MediaId> aborted = [];
  final List<MediaId> confirmed = [];
  int reserveCount = 0;
  int chunks = 4;
  int generation = 1;
  void Function()? onAbort;
  void Function()? onReserve;
  Completer<void>? holdFile;
  Completer<void>? holdReserve;
  void Function()? onChunk;

  final Map<String, List<UploadStageException>> failures = {};
  bool abortSucceeds = true;

  void failStage(String stage, UploadStageException e, {int times = 1}) {
    failures.putIfAbsent(stage, () => []).addAll(List.filled(times, e));
  }

  void _maybeFail(String stage) {
    final q = failures[stage];
    if (q != null && q.isNotEmpty) throw q.removeAt(0);
  }

  @override
  Future<Reservation> reserve(String albumId, UploadEnvelope env) async {
    calls.add('reserve');
    onReserve?.call();
    if (holdReserve != null) await holdReserve!.future;
    reserveCount++;
    _maybeFail('reserve');
    return Reservation(
      uploadUrl: 'https://store/file/$reserveCount',
      thumbUploadUrl: env.hasThumb ? 'https://store/thumb/$reserveCount' : null,
    );
  }

  Future<void> _put(
      String stage, int total, ProgressSink onBytes, CancelToken cancel) async {
    calls.add(stage);
    if (stage == 'putFile' && holdFile != null) await holdFile!.future;
    final step = (total / chunks).ceil();
    var sent = 0;
    for (var i = 0; i < chunks && sent < total; i++) {
      sent = (sent + step).clamp(0, total);
      onChunk?.call();
      onBytes(sent);
      if (cancel.isCancelled) return;
    }
    _maybeFail(stage);
  }

  @override
  Future<void> putFile(String albumId, Reservation r, UploadEnvelope env,
          {required ProgressSink onBytes, required CancelToken cancel}) =>
      _put('putFile', env.blobSize, onBytes, cancel);

  @override
  Future<void> putThumb(String albumId, Reservation r, UploadEnvelope env,
          {required ProgressSink onBytes, required CancelToken cancel}) =>
      _put('putThumb', env.thumbSize, onBytes, cancel);

  @override
  Future<int> confirm(String albumId, MediaId mediaId) async {
    calls.add('confirm');
    _maybeFail('confirm');
    confirmed.add(mediaId);
    return generation;
  }

  @override
  Future<bool> abort(String albumId, MediaId mediaId) async {
    calls.add('abort');
    onAbort?.call();
    aborted.add(mediaId);
    return abortSucceeds;
  }
}

class FakeSink implements UploadSink {
  final List<String> seeded = [];
  final List<String> settled = [];
  final List<MediaId> previewed = [];
  bool seedThrows = false;

  @override
  void onPrepared(String albumId, MediaId mediaId, Uint8List? thumb) {
    if (thumb != null) previewed.add(mediaId);
  }

  @override
  Future<void> seed(String albumId, UploadEnvelope env) async {
    if (seedThrows) throw StateError('disk full');
    seeded.add(env.mediaIdString);
  }

  @override
  Future<void> onBatchSettled(String albumId) async => settled.add(albumId);
}

class FakeClock {
  DateTime value = DateTime.utc(2026, 9, 7);
  DateTime call() => value;
  void advance(Duration d) => value = value.add(d);
}
