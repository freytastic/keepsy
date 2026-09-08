import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/api/api_client.dart';
import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/data/models/member_model.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/album/album_copy.dart';
import 'package:keepsy/ui/album/member_avatars.dart';
import 'package:keepsy/ui/screens/album_detail_screen.dart';
import 'package:keepsy/ui/shelf/shelf_data.dart';

import '../secure_store/mock_secure_key_store.dart';

import 'package:keepsy/ui/providers/upload_queue_model.dart';
import 'upload_scaffold.dart';

class _MockAlbumService extends AlbumService {
  final List<AlbumMember> members;
  _MockAlbumService(this.members);

  @override
  Future<List<AlbumMember>> listMembers(String albumId) async => members;
}

// _StubMediaApi : returns the in memory items list : never makes a real HTTP
// call. Tests construct this with whatever rows they want the screen to render
class _StubMediaApi extends MediaApi {
  final List<MediaRecord> items;
  _StubMediaApi(this.items) : super(ApiClient());

  @override
  Future<List<MediaRecord>> listMedia(String _) async => items;

  @override
  void dispose() {}
}

Future<AlbumKeyStore> _emptyAks() async {
  final s = MockSecureKeyStore();
  await s.initialize();
  final aks = AlbumKeyStore(s);
  await aks.initialize();
  return aks;
}

AlbumModel _fakeAlbum() => AlbumModel(
      id: 'album-1',
      nameCt: null,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

AlbumMember _fakeMember(String token, String role) => AlbumMember(
      memberToken: token,
      role: role,
      revoked: false,
      joinedAt: DateTime(2024),
      profile: MemberProfile(),
    );

Widget _wrap(Widget child, AlbumKeyStore aks) => MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
        Provider<AlbumKeyStore>.value(value: aks),
        ChangeNotifierProvider<UploadQueueModel>.value(
            value: idleUploadQueue()),
      ],
      child: MaterialApp(home: child),
    );

void main() {
  testWidgets('AlbumDetailScreen shows members as avatars, never as tokens',
      (tester) async {
    final aks = await _emptyAks();
    await tester.pumpWidget(_wrap(
      AlbumDetailScreen(
        album: _fakeAlbum(),
        albumService: _MockAlbumService([
          _fakeMember('alicetoken123', 'admin'),
          _fakeMember('bobtoken456', 'member'),
        ]),
        mediaApi: _StubMediaApi(const []),
      ),
      aks,
    ));
    await tester.pumpAndSettle();

    expect(find.text('alicetok'), findsNothing);
    expect(find.text('bobtoken'), findsNothing);
    expect(find.byType(MemberAvatars), findsOneWidget);
    expect(find.text('·'), findsNWidgets(2));
  });

  testWidgets('roles and safety numbers stay reachable through the menu',
      (tester) async {
    final aks = await _emptyAks();
    await tester.pumpWidget(_wrap(
      AlbumDetailScreen(
        album: _fakeAlbum(),
        albumService: _MockAlbumService([
          _fakeMember('alicetoken123', 'admin'),
          _fakeMember('bobtoken456', 'member'),
        ]),
        mediaApi: _StubMediaApi(const []),
      ),
      aks,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip(AlbumCopy.more).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(AlbumCopy.peopleAndSafety));
    await tester.pumpAndSettle();

    expect(find.text('Member'), findsNWidgets(2));
    expect(find.text('admin'), findsOneWidget);
    expect(find.text('member'), findsOneWidget);
  });

  testWidgets(
      'AlbumDetailScreen exits itself when the album is removed '
      '(kicked while viewing)', (tester) async {
    final aks = await _emptyAks();
    final appState = AppState();
    appState.setAlbums([_fakeAlbum()]);

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appState),
        Provider<AlbumKeyStore>.value(value: aks),
        ChangeNotifierProvider<UploadQueueModel>.value(
            value: idleUploadQueue()),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                  builder: (_) => AlbumDetailScreen(
                    album: _fakeAlbum(),
                    albumService: _MockAlbumService(
                        [_fakeMember('mytoken12345', 'member')]),
                    mediaApi: _StubMediaApi(const []),
                  ),
                )),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(AlbumDetailScreen), findsOneWidget);

    // the admin kicks this user -> onSelfRemoved drops the album from state
    appState.removeAlbum('album-1');
    await tester.pumpAndSettle();

    // the detail screen closed itself; we're back on the launcher
    expect(find.byType(AlbumDetailScreen), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets(
      'AlbumDetailScreen does NOT auto-exit after re-invite '
      '(stale removal signal cleared on rejoin)', (tester) async {
    final aks = await _emptyAks();
    final appState = AppState();
    appState.setAlbums([_fakeAlbum()]);
    // kicked earlier: removal signal is set for album-1
    appState.removeAlbum('album-1');
    // re invited + rejoined: album-1 comes back, which must clear the signal
    appState.prependAlbum(_fakeAlbum());
    expect(appState.lastRemovedAlbumId, isNull);

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appState),
        Provider<AlbumKeyStore>.value(value: aks),
        ChangeNotifierProvider<UploadQueueModel>.value(
            value: idleUploadQueue()),
      ],
      child: MaterialApp(
        home: AlbumDetailScreen(
          album: _fakeAlbum(),
          albumService:
              _MockAlbumService([_fakeMember('mytoken12345', 'member')]),
          mediaApi: _StubMediaApi(const []),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // the screen stayed open (was not bounced by the stale kicked while viewing
    // guard)
    expect(find.byType(AlbumDetailScreen), findsOneWidget);
  });

  testWidgets('AlbumDetailScreen shows no media placeholder', (tester) async {
    final aks = await _emptyAks();
    await tester.pumpWidget(_wrap(
      AlbumDetailScreen(
        album: _fakeAlbum(),
        albumService: _MockAlbumService([]),
        mediaApi: _StubMediaApi(const []),
      ),
      aks,
    ));
    await tester.pumpAndSettle();

    expect(find.text('No media yet'), findsOneWidget);
  });

  testWidgets('a successful realtime reload advances the seen watermark',
      (tester) async {
    final aks = await _emptyAks();
    final album = _fakeAlbum().copyWith(
      mediaCount: 4,
      mediaGeneration: 4,
      hasSummary: true,
    );
    final appState = AppState()..setAlbums([album]);
    final seen = InMemorySeenStore();

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appState),
        Provider<AlbumKeyStore>.value(value: aks),
        ChangeNotifierProvider<UploadQueueModel>.value(
            value: idleUploadQueue()),
        ListenableProvider<SeenStore>.value(value: seen),
      ],
      child: MaterialApp(
        home: AlbumDetailScreen(
          album: album,
          albumService: _MockAlbumService([]),
          mediaApi: _StubMediaApi(const []),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(seen.lastSeen(album.id), 4);

    appState.applyMediaAdded(album.id, 5);
    appState.notifyMediaAdded(album.id, 'media-5');
    await tester.pumpAndSettle();

    expect(seen.lastSeen(album.id), 5);
  });
}
