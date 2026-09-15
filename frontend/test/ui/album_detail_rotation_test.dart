import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/ui/widgets/foot_bar.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/api/api_client.dart';
import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/models/member_model.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/e2ee/rotation_recovery.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/providers/upload_queue_model.dart';
import 'package:keepsy/ui/screens/album_detail_screen.dart';

import '../secure_store/mock_secure_key_store.dart';
import 'upload_scaffold.dart';

const _albumId = 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1';

class _MockAlbumService extends AlbumService {
  @override
  Future<List<AlbumMember>> listMembers(String albumId) async => [
        AlbumMember(
          memberToken: 'bWVtYmVydG9rZW4=',
          role: 'member',
          revoked: false,
          joinedAt: DateTime(2024),
          profile: MemberProfile(),
        ),
      ];
}

class _StubMediaApi extends MediaApi {
  _StubMediaApi() : super(ApiClient());
  @override
  Future<List<MediaRecord>> listMedia(String _) async => const [];
  @override
  void dispose() {}
}

AlbumModel _album() => AlbumModel(
      id: _albumId,
      nameCt: null,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

Future<void> _pumpScreen(WidgetTester tester, RotationStatus? status) async {
  final keys = MockSecureKeyStore();
  await keys.initialize();
  final aks = AlbumKeyStore(keys);
  await aks.initialize();
  final app = AppState()..setAlbums([_album()]);
  if (status != null) app.setRotationStatus(_albumId, status);
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      Provider<AlbumKeyStore>.value(value: aks),
      ChangeNotifierProvider<UploadQueueModel>.value(value: idleUploadQueue()),
    ],
    child: MaterialApp(
      home: AlbumDetailScreen(
        album: _album(),
        albumService: _MockAlbumService(),
        mediaApi: _StubMediaApi(),
      ),
    ),
  ));
  await tester.pump();
}

RotationStatus _status(RotationPhase phase, [RotationFailure? failure]) =>
    RotationStatus(albumId: Uint8List(16), phase: phase, failure: failure);

void main() {
  testWidgets('a member sees the album waiting for its admin', (tester) async {
    await _pumpScreen(tester, _status(RotationPhase.waiting));

    expect(
        find.textContaining('Waiting for secure key rotation'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry key rotation'), findsNothing);
  });

  testWidgets('photos can still be picked while a rotation is owed',
      (tester) async {
    await _pumpScreen(tester, _status(RotationPhase.waiting));

    final add = tester.widget<MakeButton>(find.byType(MakeButton));
    expect(add.onTap, isNotNull,
        reason: 'the upload queue holds them until the rotation commits');
  });

  testWidgets('the admin sees a rotation in progress', (tester) async {
    await _pumpScreen(tester, _status(RotationPhase.rotating));

    expect(find.textContaining('Securing this album'), findsOneWidget);
  });

  testWidgets('a failed rotation offers a retry', (tester) async {
    await _pumpScreen(
        tester, _status(RotationPhase.failed, RotationFailure.unavailable));

    expect(find.textContaining('could not be sent yet'), findsOneWidget);
    expect(
        find.widgetWithText(TextButton, 'Retry key rotation'), findsOneWidget);
  });

  testWidgets('an unconfirmed identity says why the key was not sent',
      (tester) async {
    await _pumpScreen(tester,
        _status(RotationPhase.failed, RotationFailure.identityUnconfirmed));

    expect(find.textContaining('identity key could not be confirmed'),
        findsOneWidget);
  });

  testWidgets('an album that owes nothing shows no rotation banner',
      (tester) async {
    await _pumpScreen(tester, null);

    expect(find.textContaining('key rotation'), findsNothing);
    expect(find.textContaining('Securing this album'), findsNothing);
  });
}
