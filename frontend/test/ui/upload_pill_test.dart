import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/domain/upload/upload_coordinator.dart';
import 'package:keepsy/domain/upload/upload_item.dart';
import 'package:keepsy/domain/upload/upload_ports.dart';
import 'package:keepsy/ui/providers/upload_queue_model.dart';
import 'package:keepsy/ui/widgets/upload_pill.dart';
import 'package:provider/provider.dart';

import '../domain/upload/fakes.dart';

const _album = 'album-1';

void main() {
  late FakeSources sources;
  late FakeUploader uploader;
  late UploadCoordinator co;
  late UploadQueueModel model;

  setUp(() {
    sources = FakeSources();
    uploader = FakeUploader();
    co = UploadCoordinator(
      sources: sources,
      preparer: FakePreparer(),
      uploader: uploader,
      sink: FakeSink(),
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

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
        ChangeNotifierProvider<UploadQueueModel>.value(
          value: model,
          child: const MaterialApp(home: Scaffold(body: UploadPill())),
        ),
      );

  testWidgets('a clean batch is cleaned up rather than left unreachable',
      (tester) async {
    final batchId = model.startBatch(albumId: _album, sources: pick(1));
    await tester.pump(Duration.zero);
    await pump(tester);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(model.state.batch(batchId), isNull,
        reason: 'a finished batch with no screen watching must be released');
  });

  testWidgets('a clean batch waits for the open album before it is released',
      (tester) async {
    model.observeAlbum(_album);
    final batchId = model.startBatch(albumId: _album, sources: pick(1));
    await tester.pump(Duration.zero);
    await pump(tester);

    expect(model.state.batch(batchId), isNotNull);

    final mediaId = model.state.batch(batchId)!.items.single.mediaId.value;
    model.recordsLanded(_album, {mediaId});
    await tester.pump();

    expect(model.state.batch(batchId), isNull);
  });

  testWidgets('counts a failed photo as a position already passed',
      (tester) async {
    uploader.failStage('putFile',
        const UploadStageException(UploadFailureKind.transport, 'reset'),
        times: 3);
    var reserves = 0;
    uploader.onReserve = () {
      if (++reserves == 2) uploader.holdReserve = Completer<void>();
    };
    model.startBatch(albumId: _album, sources: pick(3));
    await pump(tester);
    await tester.pump(Duration.zero);
    await tester.pump();

    expect(find.text('Adding 2 of 3'), findsOneWidget);
    uploader.holdReserve!.complete();
  });

  testWidgets('stays reachable after a batch settles with losses',
      (tester) async {
    uploader.failStage('putFile',
        const UploadStageException(UploadFailureKind.transport, 'reset'),
        times: 99);
    model.startBatch(albumId: _album, sources: pick(2));
    await tester.pump(Duration.zero);
    await pump(tester);

    expect(find.text('2 didn’t send'), findsOneWidget);
  });
}
