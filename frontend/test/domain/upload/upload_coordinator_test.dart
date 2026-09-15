import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/domain/upload/upload_coordinator.dart';
import 'package:keepsy/domain/upload/upload_item.dart';
import 'package:keepsy/domain/upload/upload_ports.dart';
import 'package:keepsy/domain/upload/upload_snapshot.dart';

import 'fakes.dart';

const _album = 'album-1';
const _other = 'album-2';

void main() {
  late FakeSources sources;
  late FakePreparer preparer;
  late FakeUploader uploader;
  late FakeSink sink;
  late FakeClock clock;
  late UploadCoordinator co;

  setUp(() {
    sources = FakeSources();
    preparer = FakePreparer();
    uploader = FakeUploader();
    sink = FakeSink();
    clock = FakeClock();
    co = UploadCoordinator(
      sources: sources,
      preparer: preparer,
      uploader: uploader,
      sink: sink,
      now: clock.call,
      sleep: (_) async {},
      throttle: Duration.zero,
    );
  });

  tearDown(() => co.dispose());

  List<PickedSource> pick(int n) {
    final out = <PickedSource>[];
    for (var i = 0; i < n; i++) {
      final path = '/cache/pick/$i.jpg';
      sources.add(path);
      out.add(PickedSource(path: path));
    }
    return out;
  }

  // Let the async pump settle
  Future<void> drain() => Future<void>.delayed(Duration.zero);

  UploadBatchSnapshot snap(String batchId) => co.state.batch(batchId)!;

  group('serial execution', () {
    test('processes every item one at a time and confirms each', () async {
      final id = co.enqueue(albumId: _album, sources: pick(3));
      await drain();

      expect(uploader.confirmed.length, 3);
      expect(snap(id).doneCount, 3);
      expect(snap(id).settled, isTrue);
      expect(
        uploader.calls,
        equals(List.generate(
                3, (_) => ['reserve', 'putFile', 'putThumb', 'confirm'])
            .expand((x) => x)
            .toList()),
      );
    });

    test('refreshes the album once per batch, not once per photo', () async {
      co.enqueue(albumId: _album, sources: pick(3));
      await drain();
      expect(sink.settled, [_album]);
    });
  });

  group('source ownership', () {
    test('discards each picked file as soon as it is sealed', () async {
      final sealedAtDiscard = <int>[];
      sources.onDiscard = (_) {
        sealedAtDiscard.add(preparer.sealedIds.length);
      };
      co.enqueue(albumId: _album, sources: pick(2));
      await drain();
      expect(sealedAtDiscard, [1, 2],
          reason: 'a plaintext pick outlives only its own sealing');
    });

    test('keeps the sealed photo when a recoverable failure parks the item',
        () async {
      uploader.failStage('putFile',
          const UploadStageException(UploadFailureKind.transport, 'reset'),
          times: 9);
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();

      expect(snap(id).failedCount, 1);
      expect(preparer.stored, hasLength(1));
      expect(sources.existing, isEmpty,
          reason: 'only ciphertext is held for the retry');
    });

    test('discards immediately on an unprocessable photo', () async {
      preparer.failWith = const UploadStageException(
          UploadFailureKind.unprocessable, 'undecodable');
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();

      final item = snap(id).items.single;
      expect(item.phase, UploadPhase.failed);
      expect(item.failure!.retryable, isFalse);
      expect(sources.discarded.length, 1);
    });

    test('picker copies that never became items are still deleted', () async {
      sources.add('/cache/pick/extra-a.jpg');
      sources.add('/cache/pick/extra-b.jpg');
      await co.discardUnused(
          ['/cache/pick/extra-a.jpg', '/cache/pick/extra-b.jpg']);
      expect(sources.discarded,
          containsAll(['/cache/pick/extra-a.jpg', '/cache/pick/extra-b.jpg']));
    });

    test('cancelBatch discards sources of items never sent', () async {
      final id = co.enqueue(albumId: _album, sources: pick(3));
      await co.cancelBatch(id);
      await drain();
      expect(sources.existing, isEmpty);
    });
  });

  group('source ownership at enqueue', () {
    test('staged picks are what the queue uploads', () async {
      final staged = await co.stage(pick(2));

      expect(staged.map((s) => s.path), everyElement(startsWith('/staging/')));
      expect(sources.adopted, hasLength(2));

      final id = co.enqueue(albumId: _album, sources: staged);
      await drain();
      expect(snap(id).doneCount, 2);
    });

    test('staging preserves the mime type the picker reported', () async {
      sources.add('/cache/pick/x.heic');
      final staged = await co.stage([
        const PickedSource(path: '/cache/pick/x.heic', mimeType: 'image/heic')
      ]);

      expect(staged.single.mimeType, 'image/heic');
    });

    test('a pick that cannot be staged keeps its original path', () async {
      final staged =
          await co.stage([const PickedSource(path: '/cache/pick/gone.jpg')]);

      expect(staged.single.path, '/cache/pick/gone.jpg');
    });
  });

  group('byte accounting', () {
    test('counts file and thumbnail ciphertext, and never exceeds the payload',
        () async {
      preparer.blob = 2000;
      preparer.thumb = 250;
      final id = co.enqueue(albumId: _album, sources: pick(2));
      await drain();

      expect(snap(id).logicalBytesSent, (2000 + 250) * 2);
      for (final item in snap(id).items) {
        expect(item.fraction, lessThanOrEqualTo(1.0));
      }
      expect(snap(id).fraction, lessThanOrEqualTo(1.0));
    });

    test('a retried PUT rewinds only its own asset slice', () async {
      preparer.blob = 1000;
      preparer.thumb = 200;
      final seen = <int>[];
      co.stream.listen((s) {
        final b = s.batch(s.batches.first.batchId);
        if (b != null && b.items.isNotEmpty) {
          seen.add(b.logicalBytesSent);
        }
      });
      uploader.failStage('putThumb',
          const UploadStageException(UploadFailureKind.transport, 'reset'));
      co.enqueue(albumId: _album, sources: pick(1));
      await drain();

      expect(seen.where((v) => v > 0).reduce((a, b) => a < b ? a : b),
          greaterThanOrEqualTo(250));
      expect(seen.last, 1200);
    });
  });

  group('transfer speed', () {
    test('reports a speed while bytes are moving', () async {
      preparer.blob = 4 * 1024 * 1024;
      uploader.onChunk = () => clock.advance(const Duration(milliseconds: 200));
      var sawRateWhileSending = false;
      final sub = co.stream.listen((state) {
        for (final batch in state.batches) {
          final sending = batch.items.any((item) =>
              item.phase == UploadPhase.sendingFile ||
              item.phase == UploadPhase.sendingThumb);
          if (sending && (batch.bytesPerSecond ?? 0) > 0) {
            sawRateWhileSending = true;
          }
        }
      });
      co.enqueue(albumId: _album, sources: pick(1));
      await drain();
      await sub.cancel();

      expect(sawRateWhileSending, isTrue);
    });

    test('a waiting batch does not borrow the running one\'s speed', () async {
      preparer.blob = 4 * 1024 * 1024;
      uploader.onChunk = () => clock.advance(const Duration(milliseconds: 200));
      String? waiting;
      var checked = false;
      final sub = co.stream.listen((state) {
        final id = waiting;
        if (id == null || checked) return;
        final other = state.batch(id);
        if (other == null) return;
        final running = state.batches.firstWhere((b) => b.batchId != id);
        if ((running.bytesPerSecond ?? 0) <= 0) return;
        checked = true;
        expect(other.bytesPerSecond, isNull,
            reason: 'album-2 has nothing on the wire');
      });
      co.enqueue(albumId: _album, sources: pick(1));
      waiting = co.enqueue(albumId: _other, sources: pick(1));
      await drain();
      await sub.cancel();

      expect(checked, isTrue, reason: 'the scenario never arose');
    });

    test('a preparing photo does not show the last one\'s speed', () async {
      preparer.blob = 4 * 1024 * 1024;
      uploader.onChunk = () => clock.advance(const Duration(milliseconds: 200));
      // Hold the second photo after the first establishes a speed sample
      preparer.holdPrepare = null;
      var prepares = 0;
      final gate = Completer<void>();
      final origin = preparer;
      origin.onPrepared = () {
        if (++prepares == 2) origin.holdPrepare = gate;
      };
      final id = co.enqueue(albumId: _album, sources: pick(2));
      await drain();

      final snapshot = snap(id);
      final preparing =
          snapshot.items.any((i) => i.phase == UploadPhase.preparing);
      expect(preparing, isTrue, reason: 'the scenario never arose');
      expect(snapshot.bytesPerSecond, isNull,
          reason: 'nothing is on the wire while a photo is being locked');

      gate.complete();
      await drain();
    });

    test('a stalled transfer reads as unknown rather than zero', () async {
      preparer.blob = 1024;
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();
      clock.advance(const Duration(seconds: 30));
      expect(snap(id).bytesPerSecond, isNull);
    });
  });

  group('retry policy', () {
    test('auto retries a transport failure and then succeeds', () async {
      uploader.failStage('putFile',
          const UploadStageException(UploadFailureKind.transport, 'reset'));
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();

      expect(snap(id).doneCount, 1);
      expect(uploader.calls.where((c) => c == 'putFile').length, 2);
      expect(uploader.reserveCount, 1);
    });

    test('an expired signature re-reserves instead of aborting', () async {
      uploader.failStage(
          'putFile',
          const UploadStageException(
              UploadFailureKind.presignExpired, 'http_403'));
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();

      expect(snap(id).doneCount, 1);
      expect(uploader.reserveCount, 2);
      expect(uploader.aborted, isEmpty);
    });

    test('bounded: endless 403 gives up instead of re-presigning forever',
        () async {
      uploader.failStage(
          'putFile',
          const UploadStageException(
              UploadFailureKind.presignExpired, 'http_403'),
          times: 99);
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();

      expect(snap(id).failedCount, 1);
      expect(uploader.reserveCount, lessThanOrEqualTo(4));
    });

    test('an ambiguous confirm parks for confirm only and never aborts',
        () async {
      uploader.failStage('confirm',
          const UploadStageException(UploadFailureKind.transport, 'deadline'),
          times: 9);
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();

      final item = snap(id).items.single;
      expect(item.failure!.resumeFrom, ResumePoint.confirm);
      expect(uploader.aborted, isEmpty);
    });

    test('manual retry after an ambiguous confirm re-confirms only', () async {
      uploader.failStage('confirm',
          const UploadStageException(UploadFailureKind.transport, 'deadline'),
          times: 9);
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();
      uploader.calls.clear();
      uploader.failures.clear();

      co.retry(snap(id).items.single.id);
      await drain();

      expect(uploader.calls, ['confirm']);
      expect(snap(id).doneCount, 1);
    });

    test('manual retry after a transport park rewraps the same sealed photo',
        () async {
      uploader.failStage('putFile',
          const UploadStageException(UploadFailureKind.transport, 'reset'),
          times: 9);
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();

      final before = snap(id).items.single.mediaId;
      expect(uploader.aborted, [before]);
      uploader.failures.clear();

      co.retry(snap(id).items.single.id);
      await drain();

      expect(snap(id).doneCount, 1);
      expect(snap(id).items.single.mediaId, before);
      expect(preparer.sealedIds, [before], reason: 'never encrypted twice');
      expect(preparer.wrapped, [before, before]);
    });

    test('a terminal failure refuses manual retry', () async {
      preparer.failWith = const UploadStageException(
          UploadFailureKind.unprocessable, 'undecodable');
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();

      co.retry(snap(id).items.single.id);
      await drain();
      expect(snap(id).items.single.phase, UploadPhase.failed);
      expect(preparer.wrapped, isEmpty);
      expect(preparer.stored, isEmpty);
    });
  });

  group('abort safety', () {
    test('a retry waits for the previous abort so it cannot delete its own row',
        () async {
      final order = <String>[];
      uploader.onAbort = () => order.add('abort');
      uploader.onReserve = () => order.add('reserve');
      uploader.failStage('putFile',
          const UploadStageException(UploadFailureKind.transport, 'reset'),
          times: 9);
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();
      uploader.failures.clear();

      co.retry(snap(id).items.single.id);
      await drain();

      expect(order, ['reserve', 'abort', 'reserve']);
      expect(snap(id).doneCount, 1);
    });

    test('a cancel during an in flight reserve still cleans up the row',
        () async {
      uploader.holdReserve = Completer<void>();
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();
      expect(uploader.calls, contains('reserve'));

      final cancelling = co.cancelBatch(id);
      uploader.holdReserve!.complete();
      await cancelling;
      await drain();

      expect(uploader.aborted.length, greaterThanOrEqualTo(1),
          reason: 'the reservation created after the cancel must be aborted');
      expect(uploader.calls.contains('putFile'), isFalse);
      expect(co.state.batch(id), isNull);
    });

    test('cancelling an active item aborts whatever it reserved', () async {
      uploader.holdFile = Completer<void>();
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();

      await co.cancelBatch(id);
      uploader.holdFile?.complete();
      await drain();

      expect(uploader.aborted, isNotEmpty);
      expect(co.state.batch(id), isNull);
    });
  });

  group('confirm failures', () {
    test('a definite rejection re-prepares instead of asking confirm again',
        () async {
      uploader.failStage('confirm',
          const UploadStageException(UploadFailureKind.unknown, 'http_400'));
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();

      expect(snap(id).items.single.failure!.resumeFrom, ResumePoint.prepare);
      expect(uploader.aborted, isNotEmpty);
    });

    test('a transient confirm failure still resumes at confirm', () async {
      uploader.failStage('confirm',
          const UploadStageException(UploadFailureKind.server, 'http_503'),
          times: 9);
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();

      expect(snap(id).items.single.failure!.resumeFrom, ResumePoint.confirm);
      expect(uploader.aborted, isEmpty);
    });

    test('the album generation from confirm reaches the snapshot', () async {
      uploader.generation = 42;
      final id = co.enqueue(albumId: _album, sources: pick(2));
      await drain();
      expect(snap(id).mediaGeneration, 42);
    });
  });

  group('album pause', () {
    test('a pending rotation reports the album so recovery can start',
        () async {
      final reported = <String>[];
      final hooked = UploadCoordinator(
        sources: sources,
        preparer: preparer,
        uploader: uploader,
        sink: sink,
        onRotationPending: reported.add,
        now: clock.call,
        sleep: (_) async {},
        throttle: Duration.zero,
      );
      addTearDown(hooked.dispose);
      uploader.failStage(
          'reserve',
          const UploadStageException(
              UploadFailureKind.rotationPending, 'rotation'));
      hooked.enqueue(albumId: _album, sources: pick(2));
      await drain();

      expect(reported, [_album],
          reason: 'the second photo is held by the pause, not rejected again');
    });

    test('a pending rotation pauses the album and leaves items queued',
        () async {
      uploader.failStage(
          'reserve',
          const UploadStageException(
              UploadFailureKind.rotationPending, 'rotation'));
      final id = co.enqueue(albumId: _album, sources: pick(2));
      await drain();

      expect(snap(id).paused, PauseReason.rotationPending);
      expect(snap(id).failedCount, 0);
      expect(snap(id).doneCount, 0);
    });

    test('a paused album shows no countdown', () async {
      // Complete one photo before pausing to establish an ETA sample
      var reserves = 0;
      uploader.onReserve = () {
        if (++reserves == 2) {
          uploader.failStage(
              'reserve',
              const UploadStageException(
                  UploadFailureKind.rotationPending, 'rotation'));
        }
      };
      final id = co.enqueue(albumId: _album, sources: pick(3));
      await drain();

      expect(snap(id).paused, isNotNull);
      expect(snap(id).doneCount, 1);
      expect(snap(id).eta, isNull,
          reason: 'nothing is running, so no time can be predicted');
    });

    test('other albums keep uploading while one is paused', () async {
      uploader.failStage(
          'reserve',
          const UploadStageException(
              UploadFailureKind.rotationPending, 'rotation'));
      final blocked = co.enqueue(albumId: _album, sources: pick(1));
      // A distinct pick : the blocked album already sealed and freed its own
      sources.add('/cache/pick/other.jpg');
      final running = co.enqueue(
          albumId: _other,
          sources: [const PickedSource(path: '/cache/pick/other.jpg')]);
      await drain();

      expect(snap(blocked).paused, PauseReason.rotationPending);
      expect(snap(running).doneCount, 1);
    });

    test('resumeAlbum drains what the pause held back', () async {
      uploader.failStage(
          'reserve',
          const UploadStageException(
              UploadFailureKind.rotationPending, 'rotation'));
      final id = co.enqueue(albumId: _album, sources: pick(2));
      await drain();
      expect(snap(id).doneCount, 0);

      co.resumeAlbum(_album);
      await drain();

      expect(snap(id).doneCount, 2);
      expect(snap(id).paused, isNull);
    });
  });

  group('epoch drift', () {
    test('a stale epoch rewraps under the new one, same media id', () async {
      uploader.failStage(
          'reserve',
          const UploadStageException(
              UploadFailureKind.epochStale, 'epoch_replay'));
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();

      expect(snap(id).doneCount, 1);
      expect(preparer.wrapped.length, 2);
      expect(preparer.wrapped.first, preparer.wrapped.last);
      expect(preparer.sealedIds, hasLength(1),
          reason: 'the ciphertext never depends on the album key');
      expect(snap(id).failedCount, 0);
    });

    test('a rotation that keeps landing gives up instead of spinning',
        () async {
      uploader.failStage(
          'reserve',
          const UploadStageException(
              UploadFailureKind.epochStale, 'epoch_replay'),
          times: 99);
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();

      expect(snap(id).failedCount, 1);
      expect(preparer.wrapped.length, lessThanOrEqualTo(3));
    });
  });

  group('thumbnail stage', () {
    test('an expired signature on the thumbnail re-reserves and finishes',
        () async {
      uploader.failStage(
          'putThumb',
          const UploadStageException(
              UploadFailureKind.presignExpired, 'http_403'));
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();

      expect(snap(id).doneCount, 1);
      expect(uploader.calls.where((c) => c == 'putFile').length, 1);
      expect(uploader.calls.where((c) => c == 'putThumb').length, 2);
      expect(uploader.reserveCount, 2);
      expect(uploader.aborted, isEmpty);
    });
  });

  group('grid overlays', () {
    test('a completed item stays an overlay until the grid reconciles it',
        () async {
      co.enqueue(albumId: _album, sources: pick(2));
      await drain();
      expect(co.state.overlaysFor(_album).length, 2);
      expect(co.state.overlaysFor(_other), isEmpty);
    });
  });

  group('sheet lifecycle', () {
    test('dismissing a settled batch drops it without cancelling anything',
        () async {
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();
      co.dismissBatch(id);
      expect(co.state.batch(id), isNull);
      expect(uploader.aborted, isEmpty);
    });

    test('removeFailed drops the parked items and their sources', () async {
      uploader.failStage('putFile',
          const UploadStageException(UploadFailureKind.transport, 'reset'),
          times: 3);
      final id = co.enqueue(albumId: _album, sources: pick(2));
      await drain();
      expect(snap(id).failedCount, 1);
      expect(snap(id).doneCount, 1);

      await co.removeFailed(id);
      expect(snap(id).items.length, 1);
      expect(snap(id).failedCount, 0);
      expect(sources.existing, isEmpty);
      expect(preparer.stored, isEmpty);
    });

    test('dismissing drops the sealed photo a parked failure was holding',
        () async {
      uploader.failStage('putFile',
          const UploadStageException(UploadFailureKind.transport, 'reset'),
          times: 9);
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();
      expect(preparer.stored, hasLength(1));

      await co.dismissBatch(id);
      expect(preparer.stored, isEmpty);
      expect(sources.existing, isEmpty);
    });

    test('dismissing an unsettled batch is ignored', () async {
      uploader.failStage(
          'reserve',
          const UploadStageException(
              UploadFailureKind.rotationPending, 'rotation'));
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();
      co.dismissBatch(id);
      expect(co.state.batch(id), isNotNull);
    });
  });

  group('cancellation leaves nothing behind', () {
    test('a preview prepared after a cancel is not announced', () async {
      // Preparation cannot be interrupted
      preparer.holdPrepare = Completer<void>();
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();

      await co.cancelBatch(id);
      preparer.holdPrepare!.complete();
      await drain();

      expect(sink.previewed, isEmpty,
          reason: 'the item was gone before preparation finished');
      expect(preparer.stored, isEmpty,
          reason: 'an entry sealed after the cancel is dropped');
    });

    test('a cancel during confirmation waits instead of racing the commit',
        () async {
      uploader.holdConfirm = Completer<void>();
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();

      final cancelled = co.cancelBatch(id);
      await drain();
      uploader.holdConfirm!.complete();
      await cancelled;

      expect(uploader.aborted, isEmpty,
          reason: 'the row was committed, so deleting it would be wrong');
      expect(co.state.batches, isEmpty);
    });

    test('an album pause does not outlive the batch that caused it', () async {
      uploader.failStage(
          'reserve',
          const UploadStageException(
              UploadFailureKind.rotationPending, 'rotation'));
      final first = co.enqueue(albumId: _album, sources: pick(1));
      await drain();
      expect(snap(first).paused, PauseReason.rotationPending);

      await co.cancelBatch(first);
      await drain();

      sources.add('/cache/pick/later.jpg');
      final second = co.enqueue(
          albumId: _album,
          sources: [const PickedSource(path: '/cache/pick/later.jpg')]);
      await drain();

      expect(snap(second).doneCount, 1,
          reason: 'no queued item is left to justify holding the album');
    });
  });

  group('durable outbox', () {
    const rotation =
        UploadStageException(UploadFailureKind.rotationPending, 'rotation');

    SealedUpload leftover(String itemId, [String album = _album]) =>
        SealedUpload(
          itemId: itemId,
          albumId: album,
          mediaId: MediaId.fresh(),
          payloadByteLength: 1100,
          thumbPreview: Uint8List(4),
        );

    test('a paused album still seals new photos and frees their picks',
        () async {
      uploader.failStage('reserve', rotation);
      final id = co.enqueue(albumId: _album, sources: pick(3));
      await drain();

      expect(snap(id).paused, PauseReason.rotationPending);
      expect(preparer.stored, hasLength(3));
      expect(sources.existing, isEmpty);
      expect(preparer.wrapped, hasLength(1),
          reason: 'only the first photo reached the server before the pause');
    });

    test('resuming publishes sealed photos without rereading their picks',
        () async {
      uploader.failStage('reserve', rotation);
      final id = co.enqueue(albumId: _album, sources: pick(3));
      await drain();

      co.resumeAlbum(_album);
      await drain();

      expect(snap(id).doneCount, 3);
      expect(preparer.sealedIds, hasLength(3));
      expect(preparer.stored, isEmpty,
          reason: 'published photos leave the outbox');
    });

    test('restore requeues photos sealed by an earlier run', () async {
      preparer.leftovers = [leftover('left-1'), leftover('left-2', _other)];
      await co.restore();
      await drain();

      expect(co.state.batches, hasLength(2), reason: 'one batch per album');
      expect(co.state.batches.every((b) => b.doneCount == 1), isTrue);
      expect(preparer.sealedIds, isEmpty);
      expect(sink.previewed, hasLength(2));
      expect(preparer.stored, isEmpty);
    });

    test('restoring again never queues a photo twice', () async {
      uploader.failStage('reserve', rotation, times: 9);
      preparer.leftovers = [leftover('left-1')];
      await Future.wait([co.restore(), co.restore()]);
      await co.restore();
      await drain();

      final items = co.state.batches.expand((b) => b.items).toList();
      expect(items, hasLength(1));
    });

    test('forgetting an album drops its queue and its sealed photos', () async {
      uploader.failStage('reserve', rotation);
      co.enqueue(albumId: _album, sources: pick(2));
      await drain();
      expect(preparer.stored, hasLength(2));

      await co.forgetAlbum(_album);

      expect(co.state.overlaysFor(_album), isEmpty);
      expect(preparer.stored, isEmpty);
      expect(preparer.discardedAlbums, [_album],
          reason: 'photos an earlier run left behind go too');
      expect(uploader.aborted, isEmpty,
          reason: 'the server already refuses this device');
    });

    test('forgetting one album leaves another album queued', () async {
      uploader.failStage('reserve', rotation);
      co.enqueue(albumId: _album, sources: pick(1));
      await drain();
      preparer.leftovers = [leftover('keep', _other)];
      uploader.failStage('reserve', rotation);
      await co.restore();
      await drain();

      await co.forgetAlbum(_album);
      expect(co.state.overlaysFor(_other), hasLength(1));
      expect(preparer.stored, contains('keep'));
    });
  });

  group('cache seeding', () {
    test('a seed failure never turns a confirmed upload back into failed',
        () async {
      sink.seedThrows = true;
      final id = co.enqueue(albumId: _album, sources: pick(1));
      await drain();
      expect(snap(id).doneCount, 1);
      expect(snap(id).failedCount, 0);
    });
  });

  group('shutdown', () {
    test('waits out the running confirm and forgets every item', () async {
      final hold = uploader.holdConfirm = Completer<void>();
      co.enqueue(albumId: _album, sources: pick(2));
      await drain();
      expect(uploader.calls.last, 'confirm');

      var finished = false;
      final done = co.shutdown().then((_) => finished = true);
      await drain();
      expect(finished, isFalse,
          reason: 'a confirm in flight cannot be dropped');

      hold.complete();
      await done;
      expect(co.state.batches, isEmpty);
      expect(uploader.confirmed, hasLength(1),
          reason: 'nothing new starts once shut down');
    });

    test('a run that will not end fails the shutdown instead of passing',
        () async {
      uploader.holdConfirm = Completer<void>();
      co.enqueue(albumId: _album, sources: pick(1));
      await drain();

      await expectLater(co.shutdown(wait: const Duration(milliseconds: 10)),
          throwsA(isA<TimeoutException>()));
      expect(co.state.batches, isNotEmpty,
          reason: 'nothing is reported cleared while the item still runs');
    });
  });
}
