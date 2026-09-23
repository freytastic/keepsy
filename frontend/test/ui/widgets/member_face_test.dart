import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/models/album_summary.dart';
import 'package:keepsy/data/models/avatar_ref.dart';
import 'package:keepsy/data/storage/avatar_cache.dart';
import 'package:keepsy/data/storage/own_avatar_store.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/widgets/member_face.dart';

final _png = Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4)));
final _key = Uint8List.fromList(List<int>.filled(32, 5));

AvatarRef _ref(String id) => AvatarRef(
    avatarId: id,
    blobSize: 10,
    blobSha256: Uint8List(32),
    keyCt: Uint8List(65));

AppState _state() => AppState()
  ..setAlbums([
    AlbumModel(
      id: 'album',
      nameCt: null,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      memberToken: 'me',
      hasSummary: true,
      memberPreviews: [
        MemberPreview(memberToken: 'me', avatar: _ref('mine-on-server')),
        MemberPreview(memberToken: 'friend', avatar: _ref('theirs')),
        const MemberPreview(memberToken: 'plain'),
      ],
    ),
  ]);

void main() {
  late Directory dir;
  late List<String> fetched;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('memberface');
    fetched = [];
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, List<SingleChildWidget> providers,
      Widget child) async {
    await tester.pumpWidget(MultiProvider(
      providers: providers,
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    ));
  }

  MemberFace face(String? albumId, String token) => MemberFace(
        albumId: albumId,
        token: token,
        name: 'Noor',
        size: 30,
        style: const TextStyle(fontSize: 11),
      );

  testWidgets('shows the initial without any avatar source', (tester) async {
    await pump(tester, [ChangeNotifierProvider.value(value: _state())],
        face('album', 'plain'));
    expect(find.text('N'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('fetches, opens and shows another member\'s avatar',
      (tester) async {
    final cache = await tester.runAsync(() => AvatarCache.open(
          root: dir,
          cacheRootKey: _key,
          fetch: (albumId, token, ref) async {
            fetched.add('$albumId/$token/${ref.avatarId}');
            return _png;
          },
        ));
    await pump(
        tester,
        [
          ChangeNotifierProvider.value(value: _state()),
          ChangeNotifierProvider<AvatarCache>.value(value: cache!),
        ],
        face('album', 'friend'));
    expect(find.byType(Image), findsNothing);

    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(fetched, ['album/friend/theirs']);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('our own face comes from this phone', (tester) async {
    final own = await tester.runAsync(() async {
      final s = await OwnAvatarStore.open(
          file: File('${dir.path}/own.kec'), cacheRootKey: _key);
      await s.set(_png);
      return s;
    });
    final cache = await tester.runAsync(() => AvatarCache.open(
        root: dir,
        cacheRootKey: _key,
        fetch: (a, t, r) async {
          fetched.add(r.avatarId);
          return null;
        }));
    final state = _state()..registerSelfToken('album', 'me');
    await pump(
        tester,
        [
          ChangeNotifierProvider.value(value: state),
          ChangeNotifierProvider<OwnAvatarStore>.value(value: own!),
          ChangeNotifierProvider<AvatarCache>.value(value: cache!),
        ],
        face('album', 'me'));
    await tester.pump(const Duration(milliseconds: 300));

    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as ResizeImage).imageProvider,
        isA<MemoryImage>().having((m) => m.bytes, 'bytes', _png));
    expect(fetched, isEmpty);
  });

  testWidgets('a face with no album never looks anything up', (tester) async {
    final cache = await tester.runAsync(() => AvatarCache.open(
        root: dir,
        cacheRootKey: _key,
        fetch: (a, t, r) async {
          fetched.add(r.avatarId);
          return _png;
        }));
    await pump(
        tester,
        [
          ChangeNotifierProvider.value(value: _state()),
          ChangeNotifierProvider<AvatarCache>.value(value: cache!),
        ],
        face(null, 'friend'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(fetched, isEmpty);
    expect(find.text('N'), findsOneWidget);
  });
}
