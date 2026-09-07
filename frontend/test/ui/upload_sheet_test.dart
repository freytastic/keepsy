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
    model.observeAlbum(_album);
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

  Future<void> pumpSheet(WidgetTester tester, String batchId) async {
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<UploadQueueModel>.value(value: model),
        ChangeNotifierProvider<AppState>(create: (_) => AppState()),
      ],
      child: MaterialApp(home: Scaffold(body: UploadSheet(batchId: batchId))),
    ));
    await tester.pump();
  }

  testWidgets('counts photos and bytes actually sent', (tester) async {
    preparer.blob = 2 * 1024 * 1024;
    preparer.thumb = 0;
    final id = model.startBatch(albumId: _album, sources: pick(3));
    await tester.pump(Duration.zero);
    await pumpSheet(tester, id);

    expect(find.text('3/3'), findsOneWidget);
    expect(find.text('6.0 MB sent'), findsOneWidget);
    expect(find.text('Added 3 photos'), findsOneWidget);
  });

  testWidgets('a failed photo offers a retry that re-runs only that photo',
      (tester) async {
    uploader.failStage('putFile',
        const UploadStageException(UploadFailureKind.transport, 'reset'),
        times: 99);
    final id = model.startBatch(albumId: _album, sources: pick(1));
    await tester.pump(Duration.zero);
    await pumpSheet(tester, id);

    expect(find.text('1 photo didn’t send.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    uploader.failures.clear();
    await tester.tap(find.text('Try again'));
    await tester.pump(Duration.zero);
    await tester.pump();

    expect(find.text('Try again'), findsNothing);
    expect(find.text('1/1'), findsOneWidget);
  });

  testWidgets('Done hands off instead of dropping the tiles itself',
      (tester) async {
    final dismissed = <String>[];
    final id = model.startBatch(albumId: _album, sources: pick(1));
    await tester.pump(Duration.zero);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<UploadQueueModel>.value(value: model),
        ChangeNotifierProvider<AppState>(create: (_) => AppState()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: UploadSheet(
            batchId: id,
            onDismiss: (b) async => dismissed.add(b),
          ),
        ),
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('Done'));
    await tester.pump();

    expect(dismissed, [id]);
    expect(model.state.batch(id), isNotNull);
  });

  testWidgets('Done is withheld while a retry is still on offer',
      (tester) async {
    uploader.failStage('putFile',
        const UploadStageException(UploadFailureKind.transport, 'reset'),
        times: 99);
    final id = model.startBatch(albumId: _album, sources: pick(2));
    await tester.pump(Duration.zero);
    await pumpSheet(tester, id);

    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Done'), findsNothing);
    expect(find.text('Remove them'), findsOneWidget);
  });

  testWidgets('Remove them deletes the abandoned photos and their sources',
      (tester) async {
    uploader.failStage('putFile',
        const UploadStageException(UploadFailureKind.transport, 'reset'),
        times: 99);
    final id = model.startBatch(albumId: _album, sources: pick(1));
    await tester.pump(Duration.zero);
    await pumpSheet(tester, id);

    await tester.tap(find.text('Remove them'));
    await tester.pump(Duration.zero);
    await tester.pump();

    expect(sources.existing, isEmpty);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('an unprocessable photo is not offered a retry', (tester) async {
    preparer.failWith = const UploadStageException(
        UploadFailureKind.unprocessable, 'undecodable');
    final id = model.startBatch(albumId: _album, sources: pick(1));
    await tester.pump(Duration.zero);
    await pumpSheet(tester, id);

    expect(find.text('1 photo couldn’t be opened.'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('the title names the album once its title has decrypted',
      (tester) async {
    final appState = AppState();
    final id = model.startBatch(albumId: _album, sources: pick(2));
    await tester.pump(Duration.zero);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<UploadQueueModel>.value(value: model),
        ChangeNotifierProvider<AppState>.value(value: appState),
      ],
      child: MaterialApp(home: Scaffold(body: UploadSheet(batchId: id))),
    ));
    await tester.pump();
    expect(find.text('Added 2 photos'), findsOneWidget);

    appState.setAlbumDisplayName(_album, 'Sunset Trip');
    await tester.pump();
    expect(find.text('Added 2 photos to Sunset Trip'), findsOneWidget);
  });

  testWidgets('a paused album says it is waiting rather than failing',
      (tester) async {
    uploader.failStage(
        'reserve',
        const UploadStageException(
            UploadFailureKind.rotationPending, 'rotation'));
    final id = model.startBatch(albumId: _album, sources: pick(2));
    await tester.pump(Duration.zero);
    await pumpSheet(tester, id);

    expect(find.textContaining('finish updating its keys'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });
}
