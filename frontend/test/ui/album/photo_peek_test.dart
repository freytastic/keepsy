import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/ui/album/album_copy.dart';
import 'package:keepsy/ui/album/photo_peek.dart';

MediaRecord _shot({int blob = 1400000, DateTime? at}) => MediaRecord(
      id: 'm1',
      albumId: 'album-1',
      uploaderToken: 'alice',
      wrapNonce: Uint8List(12),
      wrapTagCT: Uint8List(48),
      epochTag: 0,
      blobSize: blob,
      blobSha256: Uint8List(32),
      mediaType: 'photo',
      mimeType: 'image/jpeg',
      createdAt: at ?? DateTime(2026, 3, 14),
    );

class _ReadyFrame extends StatefulWidget {
  final VoidCallback onReady;

  const _ReadyFrame(this.onReady);

  @override
  State<_ReadyFrame> createState() => _ReadyFrameState();
}

class _ReadyFrameState extends State<_ReadyFrame> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onReady());
  }

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(key: Key('full-image'), color: Colors.black);
}

void main() {
  late int deletes;

  Widget preview(BuildContext _) => const ColoredBox(
        key: Key('preview-image'),
        color: Colors.grey,
      );

  Widget full(BuildContext _, int width, int height, VoidCallback onReady) =>
      const ColoredBox(key: Key('full-image'), color: Colors.black);

  Future<void> push(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => PhotoPeek.show(
                context,
                record: _shot(),
                uploaderName: 'Ana',
                isOwner: false,
                onDelete: () async {},
                aspectRatio: 0.75,
                previewBuilder: preview,
                fullImageBuilder: full,
              ),
              child: const Text('hold'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('hold'));
    await tester.pump();
    await tester.pump();
  }

  Future<void> pump(
    WidgetTester tester, {
    String? uploader = 'Ana',
    bool owner = false,
    MediaRecord? record,
    double aspectRatio = 0.75,
    PeekFullImageBuilder? fullBuilder,
  }) async {
    deletes = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PhotoPeek(
          record: record ?? _shot(),
          uploaderName: uploader,
          isOwner: owner,
          onDelete: () async => deletes++,
          aspectRatio: aspectRatio,
          previewBuilder: preview,
          fullImageBuilder: fullBuilder ?? full,
          now: () => DateTime(2026, 3, 14, 12),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('shows resolved caption data without exposing member tokens',
      (tester) async {
    await pump(tester);
    expect(find.text('Ana'), findsOneWidget);
    expect(find.text('1.4 MB'), findsOneWidget);

    await pump(tester, uploader: null);
    expect(find.text('alice'), findsNothing);
    expect(find.text(AlbumCopy.unknownMember), findsOneWidget);
  });

  testWidgets('only the uploader can reach the delete flow', (tester) async {
    await pump(tester, owner: false);
    expect(find.text(AlbumCopy.delete), findsNothing);

    await pump(tester, owner: true);
    expect(find.text(AlbumCopy.delete), findsOneWidget);
  });

  testWidgets('delete requires confirmation and reports it once',
      (tester) async {
    await pump(tester, owner: true);

    await tester.tap(find.text(AlbumCopy.delete));
    await tester.pumpAndSettle();
    await tester.tap(find.text(AlbumCopy.deleteCancel));
    await tester.pumpAndSettle();
    expect(deletes, 0);

    await tester.tap(find.text(AlbumCopy.delete));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text(AlbumCopy.deleteConfirm),
    ));
    await tester.pumpAndSettle();
    expect(deletes, 1);
  });

  testWidgets('opens with the preview before the full image is ready',
      (tester) async {
    await push(tester);

    expect(find.byKey(const Key('preview-image')), findsOneWidget);
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const Key('photo-peek-full')))
          .opacity,
      0,
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('only tapping outside closes the peek', (tester) async {
    await push(tester);

    await tester.tap(find.byKey(const Key('photo-peek-frame')));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoPeek), findsOneWidget);

    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    expect(find.byType(PhotoPeek), findsNothing);
  });

  testWidgets('crossfades to the full image after its first frame',
      (tester) async {
    await pump(
      tester,
      fullBuilder: (_, __, ___, onReady) => _ReadyFrame(onReady),
    );

    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const Key('photo-peek-full')))
          .opacity,
      1,
    );
  });

  testWidgets('matches the mock photo geometry and clipping', (tester) async {
    var cacheWidth = 0;
    var cacheHeight = 0;

    await pump(
      tester,
      fullBuilder: (_, width, height, __) {
        cacheWidth = width;
        cacheHeight = height;
        return const ColoredBox(color: Colors.black);
      },
    );

    final frame = find.byKey(const Key('photo-peek-frame'));
    final size = tester.getSize(frame);
    final media = MediaQuery.of(tester.element(frame));
    final expectedWidth = math.min(
      media.size.width - 44,
      media.size.height * 0.44 * 0.75,
    );
    expect(size.width, closeTo(expectedWidth, 0.2));
    expect(size.height, closeTo(expectedWidth / 0.75, 0.2));
    final dpr = tester.view.devicePixelRatio;
    expect(cacheWidth, (size.width * dpr).ceil());
    expect(cacheHeight, (size.height * dpr).ceil());

    final clip = tester.widget<ClipRRect>(find.descendant(
      of: frame,
      matching: find.byType(ClipRRect),
    ));
    expect(clip.borderRadius, BorderRadius.circular(9));
    final decoration = tester
        .widget<DecoratedBox>(find.descendant(
          of: frame,
          matching: find.byType(DecoratedBox),
        ))
        .decoration as BoxDecoration;
    expect(decoration.boxShadow, hasLength(2));
  });

  testWidgets('keeps text styling valid on the transparent route',
      (tester) async {
    await push(tester);
    await tester.pumpAndSettle();

    final caption = tester.widget<RichText>(find
        .descendant(
          of: find.byType(PhotoPeek),
          matching: find.byType(RichText),
        )
        .first);
    final style = (caption.text as TextSpan).style!;
    expect(style.decoration, anyOf(isNull, TextDecoration.none));
  });
}
