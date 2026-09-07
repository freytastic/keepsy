import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/api/api_client.dart';
import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/models/member_model.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/epoch_processor.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/screens/album_detail_screen.dart';

import '../secure_store/mock_secure_key_store.dart';

import 'package:keepsy/ui/providers/upload_queue_model.dart';
import 'upload_scaffold.dart';

const _albumId = 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1';

class _MockAlbumService extends AlbumService {
  @override
  Future<List<AlbumMember>> listMembers(String albumId) async => [
        AlbumMember(
          memberToken: 'YWRtaW50b2tlbg==',
          role: 'admin',
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

Future<AlbumKeyStore> _emptyAks() async {
  final s = MockSecureKeyStore();
  await s.initialize();
  final aks = AlbumKeyStore(s);
  await aks.initialize();
  return aks;
}

AlbumModel _album() => AlbumModel(
      id: _albumId,
      nameCt: null,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

EpochBlocked _block(EpochBlockReason reason) => EpochBlocked(
      albumId: Uint8List.fromList(List<int>.filled(16, 0xA1)),
      epoch: 4,
      reason: reason,
      senderToken: Uint8List.fromList(List<int>.filled(32, 2)),
      presentedIk: Uint8List.fromList(List<int>.filled(32, 0x22)),
    );

Future<AppState> _pumpScreen(WidgetTester tester, {EpochBlocked? block}) async {
  final aks = await _emptyAks();
  final app = AppState();
  if (block != null) app.setKeyBlock(_albumId, block);
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
  return app;
}

void main() {
  testWidgets('a blocked album says so instead of looking merely empty',
      (tester) async {
    await _pumpScreen(tester, block: _block(EpochBlockReason.signerMismatch));

    expect(find.textContaining('New photos are paused'), findsOneWidget);
    expect(find.byIcon(Icons.gpp_maybe_outlined), findsOneWidget);
  });

  testWidgets('a peer key mismatch points at the safety number',
      (tester) async {
    await _pumpScreen(tester, block: _block(EpochBlockReason.signerMismatch));

    expect(find.widgetWithText(TextButton, 'Verify safety number'),
        findsOneWidget);
  });

  testWidgets('an unfetchable wrap offers a retry instead', (tester) async {
    await _pumpScreen(tester, block: _block(EpochBlockReason.wrapUnavailable));

    expect(find.widgetWithText(TextButton, 'Retry encryption sync'),
        findsOneWidget);
    expect(
        find.widgetWithText(TextButton, 'Verify safety number'), findsNothing);
  });

  // Our own key cannot be confirmed by a human : there is nothing to compare
  testWidgets('a self signer mismatch offers no verification path',
      (tester) async {
    await _pumpScreen(tester,
        block: _block(EpochBlockReason.selfSignerMismatch));

    expect(
        find.widgetWithText(TextButton, 'Verify safety number'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Retry encryption sync'),
        findsOneWidget);
  });

  // A token without signer authority is resolved like a mismatch: compare its
  // digits out of band, then bind that exact key to the token
  testWidgets('an unknown signer points at the safety number', (tester) async {
    await _pumpScreen(tester, block: _block(EpochBlockReason.unknownSigner));

    expect(find.widgetWithText(TextButton, 'Verify safety number'),
        findsOneWidget);
  });

  testWidgets('a missing local prekey offers a retry', (tester) async {
    await _pumpScreen(tester, block: _block(EpochBlockReason.localKeyMissing));

    expect(find.widgetWithText(TextButton, 'Retry encryption sync'),
        findsOneWidget);
    expect(find.textContaining('New photos are paused'), findsOneWidget);
  });

  testWidgets('a refused replay offers a retry', (tester) async {
    await _pumpScreen(tester, block: _block(EpochBlockReason.replayRejected));

    expect(find.widgetWithText(TextButton, 'Retry encryption sync'),
        findsOneWidget);
    expect(find.textContaining('New photos are paused'), findsOneWidget);
  });

  testWidgets('uploads are disabled while an album is blocked', (tester) async {
    await _pumpScreen(tester, block: _block(EpochBlockReason.signerMismatch));

    final fab =
        tester.widget<FloatingActionButton>(find.byType(FloatingActionButton));
    expect(fab.onPressed, isNull,
        reason: 'a photo sealed now could go under a key we refused to trust');
  });

  testWidgets('an unblocked album keeps uploading', (tester) async {
    await _pumpScreen(tester);

    final fab =
        tester.widget<FloatingActionButton>(find.byType(FloatingActionButton));
    expect(fab.onPressed, isNotNull);
  });
}
