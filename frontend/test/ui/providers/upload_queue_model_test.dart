import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/domain/upload/upload_coordinator.dart';
import 'package:keepsy/domain/upload/upload_item.dart';
import 'package:keepsy/domain/upload/upload_ports.dart';
import 'package:keepsy/ui/providers/upload_queue_model.dart';

import '../../domain/upload/fakes.dart';

const _album = 'album-1';

void main() {
  late FakeSources sources;
  late FakePreparer preparer;
  late FakeUploader uploader;
  late FakeSink sink;
  late UploadCoordinator co;
  late UploadQueueModel model;

  setUp(() {
    sources = FakeSources();
    preparer = FakePreparer();
    uploader = FakeUploader();
    sink = FakeSink();
    co = UploadCoordinator(
      sources: sources,
      preparer: preparer,
      uploader: uploader,
      sink: sink,
      sleep: (_) async {},
      throttle: Duration.zero,
    );
    model = UploadQueueModel(co);
  });

  tearDown(() async {
    model.dispose();
    await co.dispose();
  });

  List<PickedSource> pick(int n) => [
        for (var i = 0; i < n; i++)
          () {
            sources.add('/cache/pick/$i.jpg');
            return PickedSource(path: '/cache/pick/$i.jpg');
          }(),
      ];

  Future<String> settledBatch(int n) async {
    final id = model.startBatch(albumId: _album, sources: pick(n));
    await pumpEventQueue();
    return id;
  }

  group('awaited mutations leave the exposed state current', () {
    test('removeFailed', () async {
      uploader.failStage('putFile',
          const UploadStageException(UploadFailureKind.transport, 'reset'),
          times: 99);
      final id = await settledBatch(2);
      expect(model.state.batch(id), isNotNull);

      await model.removeFailed(id);

      expect(model.state.batch(id), isNull);
    });

    test('cancelBatch', () async {
      uploader.holdFile = Completer<void>();
      final id = await settledBatch(2);

      await model.cancelBatch(id);

      expect(model.state.batch(id), isNull);
      uploader.holdFile!.complete();
    });

    test('dismissBatch', () async {
      final id = await settledBatch(2);

      await model.dismissBatch(id);

      expect(model.state.batch(id), isNull);
    });
  });

  group('presentation ownership', () {
    // Presentation prevents auto sweep without an observing album
    String presentedBatch(int n) {
      final id = model.startBatch(albumId: _album, sources: pick(n));
      model.beginPresenting(id);
      return id;
    }

    test('a presented batch survives an auto release', () async {
      final id = presentedBatch(2);
      await pumpEventQueue();

      expect(model.state.batch(id), isNotNull);
    });

    test('releasing presentation lets the pending sweep finish', () async {
      final id = presentedBatch(2);
      await pumpEventQueue();
      expect(model.state.batch(id), isNotNull);

      model.endPresenting(id);
      await pumpEventQueue();

      expect(model.state.batch(id), isNull);
    });

    test('two presenters both have to let go', () async {
      final id = presentedBatch(2);
      model.beginPresenting(id);
      await pumpEventQueue();

      model.endPresenting(id);
      await pumpEventQueue();
      expect(model.state.batch(id), isNotNull);

      model.endPresenting(id);
      await pumpEventQueue();
      expect(model.state.batch(id), isNull);
    });
  });

  group('optimistic previews', () {
    test('a preview for unknown media is refused', () async {
      final orphan = MediaId.fresh();

      model.putPreview(orphan, Uint8List.fromList([1, 2, 3]));

      expect(model.preview(orphan), isNull,
          reason: 'holding plaintext for media the queue dropped is a leak');
    });

    test('a preview for a live item is kept', () async {
      uploader.holdConfirm = Completer<void>();
      final id = model.startBatch(albumId: _album, sources: pick(1));
      await pumpEventQueue();
      final live = model.state.batch(id)!.items.single.mediaId;

      model.putPreview(live, Uint8List.fromList([1, 2, 3]));

      expect(model.preview(live), isNotNull);
      uploader.holdConfirm!.complete();
    });
  });

  group('observer ownership', () {
    test('one screen closing does not release a batch another still shows',
        () async {
      model.observeAlbum(_album);
      model.observeAlbum(_album);
      final id = await settledBatch(2);

      model.stopObserving(_album);
      await pumpEventQueue();

      expect(model.state.batch(id), isNotNull,
          reason: 'a second screen is still displaying these tiles');

      model.stopObserving(_album);
      await pumpEventQueue();

      expect(model.state.batch(id), isNull);
    });
  });
}
