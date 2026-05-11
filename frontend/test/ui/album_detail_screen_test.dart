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
import 'package:keepsy/ui/screens/album_detail_screen.dart';

import '../secure_store/mock_secure_key_store.dart';

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
      name: 'Untitled Album',
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
      ],
      child: MaterialApp(home: child),
    );

void main() {
  testWidgets('AlbumDetailScreen shows member chips', (tester) async {
    final aks = await _emptyAks();
    // M7 : member display name is the first 8 chars of the pseudonymous token
    // until name_ct decryption wires up in Phase 5
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

    expect(find.text('alicetok'), findsOneWidget);
    expect(find.text('bobtoken'), findsOneWidget);
    expect(find.text('admin'), findsOneWidget);
    expect(find.text('member'), findsOneWidget);
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
}
