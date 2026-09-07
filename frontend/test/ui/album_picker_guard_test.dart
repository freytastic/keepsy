import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/api/api_client.dart';
import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/models/member_model.dart';
import 'package:keepsy/data/storage/media_catalog.dart';
import 'package:keepsy/domain/upload/upload_coordinator.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/providers/upload_queue_model.dart';
import 'package:keepsy/ui/screens/album_detail_screen.dart';
import 'package:keepsy/ui/widgets/upload_sheet.dart';
import 'package:provider/provider.dart';

import '../domain/upload/fakes.dart';
import '../secure_store/mock_secure_key_store.dart';

class _MockAlbumService extends AlbumService {
  @override
  Future<List<AlbumMember>> listMembers(String albumId) async => const [];
}

class _EmptyMediaApi extends MediaApi {
  _EmptyMediaApi() : super(ApiClient());
  @override
  Future<List<MediaRecord>> listMedia(String _) async => const [];
  @override
  void dispose() {}
}

class _EmptyCatalog implements MediaCatalog {
  @override
  Future<List<MediaRecord>> listRecordsForAlbum(String albumId) async =>
      const [];
  @override
  Future<void> reconcileAlbum(String a, List<MediaRecord> r) async {}
}

void main() {
  late UploadCoordinator co;
  late UploadQueueModel model;
  late FakeSources sources;
  late FakeUploader uploader;

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

  Future<AlbumKeyStore> emptyAks() async {
    final s = MockSecureKeyStore();
    await s.initialize();
    final aks = AlbumKeyStore(s);
    await aks.initialize();
    return aks;
  }

  Future<void> pumpScreen(WidgetTester tester, MultiImagePicker picker) async {
    final aks = await emptyAks();
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
        Provider<AlbumKeyStore>.value(value: aks),
        ChangeNotifierProvider<UploadQueueModel>.value(value: model),
        Provider<MediaCatalog>.value(value: _EmptyCatalog()),
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
          mediaApi: _EmptyMediaApi(),
          pickImages: picker,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a second tap while the picker is open is ignored',
      (tester) async {
    var opened = 0;
    final gate = Completer<List<XFile>>();
    await pumpScreen(tester, ({int limit = 0}) {
      opened++;
      return gate.future;
    });

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();

    expect(opened, 1);

    gate.complete(const []);
    await tester.pumpAndSettle();
  });

  testWidgets('the picker can be reopened after it returns nothing',
      (tester) async {
    var opened = 0;
    await pumpScreen(tester, ({int limit = 0}) async {
      opened++;
      return const [];
    });

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(opened, 2, reason: 'a cancelled pick must not sticky-lock the FAB');
  });

  testWidgets('a picker failure is surfaced instead of going unhandled',
      (tester) async {
    await pumpScreen(tester, ({int limit = 0}) async {
      throw PlatformException(code: 'already_active');
    });

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('Pick different photos can reopen the picker', (tester) async {
    var opened = 0;
    sources.add('/cache/pick/bad.jpg');
    await pumpScreen(tester, ({int limit = 0}) async {
      opened++;
      return [XFile('/cache/pick/bad.jpg')];
    });
    uploader.holdReserve = Completer<void>();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(opened, 1);
    expect(find.byType(UploadSheet), findsOneWidget);

    // The first call still awaits the sheet
    final state = tester.state<State>(find.byType(UploadSheet));
    (state.widget as UploadSheet).onPickMore!();
    await tester.pump();

    expect(opened, 2,
        reason: 'the guard must cover the picker, not the sheet lifetime');
    uploader.holdReserve!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('leaving mid-stage does not strand the plaintext copies',
      (tester) async {
    sources.add('/cache/pick/a.jpg');
    await pumpScreen(tester, ({int limit = 0}) async {
      return [XFile('/cache/pick/a.jpg')];
    });
    sources.holdAdopt = Completer<void>();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    sources.holdAdopt!.complete();
    await tester.pumpAndSettle();

    expect(sources.discarded, isNotEmpty,
        reason: 'staged picks with no batch are unreferenced plaintext');
  });

  testWidgets('the FAB works again after a picker failure', (tester) async {
    var opened = 0;
    await pumpScreen(tester, ({int limit = 0}) async {
      opened++;
      throw PlatformException(code: 'already_active');
    });

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(opened, 2);
  });
}
