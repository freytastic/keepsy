import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/models/member_model.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/screens/album_detail_screen.dart';

class _MockAlbumService extends AlbumService {
  final List<AlbumMember> members;
  _MockAlbumService(this.members);

  @override
  Future<List<AlbumMember>> listMembers(String albumId) async => members;
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

Widget _wrap(Widget child) => ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp(home: child),
    );

void main() {
  testWidgets('AlbumDetailScreen shows member chips', (tester) async {
    // M7 : member display name is the first 8 chars of the pseudonymous token
    // until name_ct decryption wires up in Phase 5
    await tester.pumpWidget(_wrap(
      AlbumDetailScreen(
        album: _fakeAlbum(),
        albumService: _MockAlbumService([
          _fakeMember('alicetoken123', 'admin'),
          _fakeMember('bobtoken456', 'member'),
        ]),
      ),
    ));
    await tester.pump();

    expect(find.text('alicetok'), findsOneWidget);
    expect(find.text('bobtoken'), findsOneWidget);
    expect(find.text('admin'), findsOneWidget);
    expect(find.text('member'), findsOneWidget);
  });

  testWidgets('AlbumDetailScreen shows no media placeholder', (tester) async {
    await tester.pumpWidget(_wrap(
      AlbumDetailScreen(
        album: _fakeAlbum(),
        albumService: _MockAlbumService([]),
      ),
    ));
    await tester.pump();

    expect(find.text('No media yet'), findsOneWidget);
  });
}
