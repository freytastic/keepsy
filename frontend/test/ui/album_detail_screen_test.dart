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

AlbumMember _fakeMember(String name, String role) => AlbumMember(
      memberToken: 'tok${name.toLowerCase()}',
      role: role,
      revoked: false,
      joinedAt: DateTime(2024),
      profile: MemberProfile(name: name),
    );

Widget _wrap(Widget child) => ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp(home: child),
    );

void main() {
  testWidgets('AlbumDetailScreen shows member chips', (tester) async {
    await tester.pumpWidget(_wrap(
      AlbumDetailScreen(
        album: _fakeAlbum(),
        albumService: _MockAlbumService([
          _fakeMember('Alice', 'admin'),
          _fakeMember('Bob', 'member'),
        ]),
      ),
    ));
    await tester.pump();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
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
