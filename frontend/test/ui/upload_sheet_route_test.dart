import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/domain/upload/upload_coordinator.dart';
import 'package:keepsy/domain/upload/upload_item.dart';
import 'package:keepsy/domain/upload/upload_ports.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/providers/upload_queue_model.dart';
import 'package:keepsy/ui/widgets/upload_sheet.dart';
import 'package:provider/provider.dart';

import '../domain/upload/fakes.dart';

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

  // Uses a real route to exercise sheet ownership
  Future<void> pumpHost(WidgetTester tester, String batchId) async {
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<UploadQueueModel>.value(value: model),
        ChangeNotifierProvider<AppState>(create: (_) => AppState()),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => UploadSheet.show(context, batchId: batchId),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    // Avoid pumpAndSettle while the upload is held
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('a batch settling before the sheet builds is still held',
      (tester) async {
    uploader.holdFile = Completer<void>();
    final id = model.startBatch(albumId: _album, sources: pick(1));
    await tester.pump(Duration.zero);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<UploadQueueModel>.value(value: model),
        ChangeNotifierProvider<AppState>(create: (_) => AppState()),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => UploadSheet.show(context, batchId: id),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));

    UploadSheet.show(tester.element(find.text('open')), batchId: id);
    uploader.holdFile!.complete();
    await tester.pumpAndSettle();

    expect(model.state.batch(id), isNotNull,
        reason: 'the sheet already owns this batch, even before it builds');
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('a settled batch is not swept away under its open sheet',
      (tester) async {
    uploader.holdFile = Completer<void>();
    final id = model.startBatch(albumId: _album, sources: pick(2));
    await tester.pump(Duration.zero);
    await pumpHost(tester, id);

    uploader.holdFile!.complete();
    await tester.pumpAndSettle();

    expect(model.state.batch(id), isNotNull);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('closing the sheet releases the batch it was holding',
      (tester) async {
    uploader.holdFile = Completer<void>();
    final id = model.startBatch(albumId: _album, sources: pick(2));
    await tester.pump(Duration.zero);
    await pumpHost(tester, id);

    uploader.holdFile!.complete();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(model.state.batch(id), isNull);
  });

  testWidgets('Done from the pill holds overlays until the records land',
      (tester) async {
    model.observeAlbum(_album);
    final id = model.startBatch(albumId: _album, sources: pick(2));
    await tester.pump(Duration.zero);
    await pumpHost(tester, id);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(model.state.batch(id), isNotNull,
        reason: 'overlays must survive until the album listing has them');

    final landed = {
      for (final i in model.state.batch(id)!.items) i.mediaId.value
    };
    model.recordsLanded(_album, landed);
    await tester.pump();

    expect(model.state.batch(id), isNull);
  });

  testWidgets('a sheet whose batch disappears closes its own route',
      (tester) async {
    model.observeAlbum(_album);
    final id = model.startBatch(albumId: _album, sources: pick(1));
    await tester.pump(Duration.zero);
    await pumpHost(tester, id);

    await model.cancelBatch(id);
    await tester.pumpAndSettle();

    expect(find.text('open'), findsOneWidget);
    expect(find.byType(UploadSheet), findsNothing);
  });

  testWidgets('a blocked close is retried once the sheet is on top again',
      (tester) async {
    model.observeAlbum(_album);
    final id = model.startBatch(albumId: _album, sources: pick(1));
    await tester.pump(Duration.zero);
    await pumpHost(tester, id);

    final nav = Navigator.of(tester.element(find.byType(UploadSheet)));
    unawaited(showDialog<void>(
      context: tester.element(find.byType(UploadSheet)),
      builder: (_) => const AlertDialog(content: Text('blocker')),
    ));
    await tester.pumpAndSettle();

    await model.cancelBatch(id);
    await tester.pumpAndSettle();
    expect(find.byType(UploadSheet), findsOneWidget,
        reason: 'the sheet cannot pop while it is not the current route');

    nav.pop();
    await tester.pumpAndSettle();

    expect(find.byType(UploadSheet), findsNothing,
        reason: 'the close must resume once the sheet is current again');
    expect(find.text('open'), findsOneWidget);
  });

  // Keeps a route below the sheet to detect stray pops
  Future<void> pumpNestedHost(WidgetTester tester, String batchId) async {
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<UploadQueueModel>.value(value: model),
        ChangeNotifierProvider<AppState>(create: (_) => AppState()),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (inner) => Scaffold(
                      body: Center(
                        child: TextButton(
                          onPressed: () =>
                              UploadSheet.show(inner, batchId: batchId),
                          child: const Text('album'),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('shelf'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('shelf'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('album'));
    await tester.pumpAndSettle();
  }

  testWidgets('a delayed Remove them cannot pop a route it no longer owns',
      (tester) async {
    uploader.failStage('putFile',
        const UploadStageException(UploadFailureKind.transport, 'reset'),
        times: 99);
    final id = model.startBatch(albumId: _album, sources: pick(1));
    await tester.pump(Duration.zero);
    await pumpNestedHost(tester, id);

    sources.holdDiscard = Completer<void>();
    await tester.tap(find.text('Remove them'));
    await tester.pump();

    Navigator.of(tester.element(find.text('album'))).pop();
    await tester.pumpAndSettle();

    sources.holdDiscard!.complete();
    await tester.pumpAndSettle();

    expect(find.text('album'), findsOneWidget,
        reason: 'the late pop must not close the album underneath');
  });
}
