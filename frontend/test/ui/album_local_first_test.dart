import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/api/api_client.dart';
import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/models/member_model.dart';
import 'package:keepsy/data/storage/media_cache_manager.dart';
import 'package:keepsy/data/storage/media_catalog.dart';
import 'package:keepsy/data/storage/media_plaintext_cache.dart';
import 'package:keepsy/data/storage/media_sealed_cache.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/screens/album_detail_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../secure_store/mock_secure_key_store.dart';

import 'package:keepsy/ui/providers/upload_queue_model.dart';
import 'upload_scaffold.dart';

// SQLite futures do not settle under widget-test fake time
class _FakeCatalog implements MediaCatalog {
  final Map<String, List<MediaRecord>> rows;
  _FakeCatalog([Map<String, List<MediaRecord>>? seed]) : rows = seed ?? {};

  @override
  Future<List<MediaRecord>> listRecordsForAlbum(String albumId) async =>
      List.of(rows[albumId] ?? const []);

  @override
  Future<void> reconcileAlbum(String a, List<MediaRecord> records) async {
    rows[a] = List.of(records);
  }
}

class _MockAlbumService extends AlbumService {
  @override
  Future<List<AlbumMember>> listMembers(String albumId) async => [];
}

class _StubMediaApi extends MediaApi {
  final List<MediaRecord>? items;
  final Object? error;
  final Completer<void>? gate;
  int calls = 0;

  _StubMediaApi({this.items, this.error, this.gate}) : super(ApiClient());

  @override
  Future<List<MediaRecord>> listMedia(String _) async {
    calls++;
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    return items ?? [];
  }

  @override
  void dispose() {}
}

MediaRecord _rec(String id) => MediaRecord(
      id: id,
      albumId: 'album-1',
      uploaderToken: 'tok',
      wrapNonce: Uint8List(12),
      wrapTagCT: Uint8List(48),
      epochTag: 0,
      blobSize: 10,
      blobSha256: Uint8List(32),
      mediaType: 'photo',
      mimeType: 'image/jpeg',
      createdAt: DateTime.utc(2026),
      thumbWrapNonce: Uint8List(12),
      thumbWrapTagCT: Uint8List(48),
      thumbSize: 5,
      thumbSha256: Uint8List(32),
    );

AlbumModel _album() => AlbumModel(
      id: 'album-1',
      nameCt: null,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late _FakeCatalog catalog;
  late AlbumKeyStore aks;
  late Directory dir;
  late MediaSealedCache sealed;

  setUp(() async {
    catalog = _FakeCatalog();
    final store = MockSecureKeyStore();
    await store.initialize();
    aks = AlbumKeyStore(store);
    await aks.initialize();
    dir = await Directory.systemTemp.createTemp('keepsy_lf');
    sealed =
        await MediaSealedCache.open(rootDir: dir, cacheRootKey: Uint8List(32));
  });

  tearDown(() async {
    await sealed.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Widget wrap(MediaApi api) => MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AppState()),
          Provider<AlbumKeyStore>.value(value: aks),
          ChangeNotifierProvider<UploadQueueModel>.value(
              value: idleUploadQueue()),
          Provider<MediaCatalog>.value(value: catalog),
          Provider<MediaCacheManager>.value(
            value: MediaCacheManager(
              plaintext: MediaPlaintextCache(),
              ciphertext: sealed,
              api: api as MediaApiInterface,
              aks: aks,
            ),
          ),
        ],
        child: MaterialApp(
          home: AlbumDetailScreen(
            album: _album(),
            albumService: _MockAlbumService(),
            mediaApi: api,
          ),
        ),
      );

  testWidgets('a cached album paints before the network answers',
      (tester) async {
    await catalog.reconcileAlbum('album-1', [_rec('a'), _rec('b')]);
    final gate = Completer<void>();
    final api = _StubMediaApi(items: [_rec('a'), _rec('b')], gate: gate);

    await tester.pumpWidget(wrap(api));
    await tester.pump(); // local read completes
    await tester.pump();

    expect(find.byType(SliverGrid), findsOneWidget,
        reason: 'grid must render from the catalog while listMedia is pending');
    expect(api.calls, 1, reason: 'the refresh is in flight, not yet answered');

    gate.complete();
    await settle(tester);
  });

  testWidgets('a failed refresh keeps the cached album on screen',
      (tester) async {
    await catalog.reconcileAlbum('album-1', [_rec('a'), _rec('b')]);
    final api = _StubMediaApi(error: Exception('offline'));

    await tester.pumpWidget(wrap(api));
    await settle(tester);

    expect(find.byType(SliverGrid), findsOneWidget);
    expect(find.textContaining('No media yet'), findsNothing);
    expect(find.text('Retry'), findsOneWidget,
        reason: 'stale content should offer an explicit refresh');
  });

  testWidgets('an empty album is only declared after an authoritative answer',
      (tester) async {
    final api = _StubMediaApi(items: []);

    await tester.pumpWidget(wrap(api));
    await settle(tester);

    expect(find.byType(SliverGrid), findsNothing);
    expect(find.textContaining('No media yet'), findsOneWidget);
  });

  testWidgets('a cold album with a failed refresh does not claim to be empty',
      (tester) async {
    final api = _StubMediaApi(error: Exception('offline'));

    await tester.pumpWidget(wrap(api));
    await settle(tester);

    expect(find.textContaining('No media yet'), findsNothing);
    expect(find.textContaining("Couldn't load"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('a successful refresh writes the catalog for the next open',
      (tester) async {
    final api = _StubMediaApi(items: [_rec('x'), _rec('y')]);

    await tester.pumpWidget(wrap(api));
    await settle(tester);

    final saved = await catalog.listRecordsForAlbum('album-1');
    expect([for (final r in saved) r.id], ['x', 'y']);
  });
}
