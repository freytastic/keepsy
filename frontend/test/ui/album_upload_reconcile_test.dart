import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/api/api_client.dart';
import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/models/member_model.dart';
import 'package:keepsy/domain/upload/upload_coordinator.dart';
import 'package:keepsy/domain/upload/upload_item.dart';
import 'package:keepsy/domain/upload/upload_ports.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/providers/upload_queue_model.dart';
import 'package:keepsy/ui/screens/album_detail_screen.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/data/storage/media_catalog.dart';

import '../domain/upload/fakes.dart';
import '../secure_store/mock_secure_key_store.dart';

class _MockAlbumService extends AlbumService {
  @override
  Future<List<AlbumMember>> listMembers(String albumId) async => const [];
}

class _CountingMediaApi extends MediaApi {
  int listCalls = 0;
  _CountingMediaApi() : super(ApiClient());

  @override
  Future<List<MediaRecord>> listMedia(String _) async {
    listCalls++;
    return const [];
  }

  @override
  void dispose() {}
}

class _RecordingCatalog implements MediaCatalog {
  final List<List<String>> reconciled = [];

  @override
  Future<List<MediaRecord>> listRecordsForAlbum(String albumId) async =>
      const [];

  @override
  Future<void> reconcileAlbum(String albumId, List<MediaRecord> records) async {
    reconciled.add([for (final r in records) r.id]);
  }
}

void main() {
  late FakeSources sources;
  late FakePreparer preparer;
  late FakeUploader uploader;
  late UploadCoordinator co;
  late UploadQueueModel model;
  late _CountingMediaApi media;
  late _RecordingCatalog catalog;

  setUp(() {
    sources = FakeSources();
    preparer = FakePreparer();
    uploader = FakeUploader();
    co = UploadCoordinator(
      sources: sources,
      preparer: preparer,
      uploader: uploader,
      sink: FakeSink(),
      sleep: (_) async {},
      throttle: Duration.zero,
    );
    model = UploadQueueModel(co);
    media = _CountingMediaApi();
    catalog = _RecordingCatalog();
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

  Future<AlbumKeyStore> emptyAks() async {
    final s = MockSecureKeyStore();
    await s.initialize();
    final aks = AlbumKeyStore(s);
    await aks.initialize();
    return aks;
  }

  Future<void> pumpScreen(WidgetTester tester, AlbumKeyStore aks) async {
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
        Provider<AlbumKeyStore>.value(value: aks),
        ChangeNotifierProvider<UploadQueueModel>.value(value: model),
        Provider<MediaCatalog>.value(value: catalog),
      ],
      child: MaterialApp(
        home: AlbumDetailScreen(
          album: AlbumModel(
            id: 'album-1',
            nameCt: null,
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
          albumService: _MockAlbumService(),
          mediaApi: media,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a batch that settles twice reconciles twice', (tester) async {
    final aks = await emptyAks();
    uploader.failStage('putFile',
        const UploadStageException(UploadFailureKind.transport, 'reset'),
        times: 3);
    await pumpScreen(tester, aks);
    final settledOnOpen = media.listCalls;

    model.startBatch(albumId: 'album-1', sources: pick(2));
    await tester.pumpAndSettle();
    final afterFirstSettle = media.listCalls;
    expect(afterFirstSettle, greaterThan(settledOnOpen),
        reason: 'the successful photo must trigger a reload');

    uploader.failures.clear();
    final batchId = model.state.batches.last.batchId;
    model.retryFailed(batchId);
    await tester.pumpAndSettle();

    expect(media.listCalls, greaterThan(afterFirstSettle));
  });

  testWidgets('a completed upload reloads the album without a server event',
      (tester) async {
    final aks = await emptyAks();
    await pumpScreen(tester, aks);
    final before = media.listCalls;

    model.startBatch(albumId: 'album-1', sources: pick(1));
    await tester.pumpAndSettle();

    expect(media.listCalls, greaterThan(before),
        reason: 'the uploader is left out of media_added on purpose');
  });
}
