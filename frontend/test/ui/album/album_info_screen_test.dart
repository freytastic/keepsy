import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/ui/album/album_copy.dart';
import 'package:keepsy/ui/album/album_info_screen.dart';
import 'package:keepsy/ui/album/album_stats.dart';

MediaRecord _shot(String id, String by, int blob) => MediaRecord(
      id: id,
      albumId: 'album-1',
      uploaderToken: by,
      wrapNonce: Uint8List(12),
      wrapTagCT: Uint8List(48),
      epochTag: 0,
      blobSize: blob,
      blobSha256: Uint8List(32),
      mediaType: 'photo',
      mimeType: 'image/jpeg',
      createdAt: DateTime(2026),
    );

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<MediaRecord> records,
    Map<String, String> names = const {},
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: AlbumInfoScreen(
        albumName: 'Lisbon',
        createdAt: DateTime(2026, 3, 14),
        stats: AlbumStats.of(records, peopleCount: 2),
        nameOf: (token) => names[token],
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('an uploader whose name has not decrypted is not named by token',
      (tester) async {
    await pump(tester, records: [_shot('a', 'secret-token', 1000)]);

    expect(find.textContaining('secret'), findsNothing);
    expect(find.text(AlbumCopy.unknownMember), findsOneWidget);
  });
}
