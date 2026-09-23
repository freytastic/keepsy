import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:keepsy/e2ee/avatar_image.dart';
import 'package:keepsy/ui/shelf/avatar_crop_screen.dart';

// 400 x 200: a landscape photo whose short side sets the crop square
final _source =
    Uint8List.fromList(img.encodePng(img.Image(width: 400, height: 200)));

void main() {
  late List<AvatarCrop> crops;
  late Object? popped;

  Future<void> open(WidgetTester tester, {bool fail = false}) async {
    crops = [];
    popped = null;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: TextButton(
            onPressed: () async {
              popped =
                  await Navigator.of(ctx).push<Uint8List>(MaterialPageRoute(
                      builder: (_) => AvatarCropScreen(
                            source: _source,
                            render: (source, crop) async {
                              crops.add(crop);
                              if (fail) throw Exception('decode');
                              return Uint8List.fromList([1, 2, 3]);
                            },
                          )));
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Reading the photo size is real engine work
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
  }

  testWidgets('starts centred on the full short side', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('avatar-use')));
    await tester.pumpAndSettle();

    final c = crops.single;
    expect(c.side, 200);
    expect(c.y, 0);
    expect(c.x, 100);
    expect(popped, [1, 2, 3]);
  });

  testWidgets('dragging past the edge stops at the edge', (tester) async {
    await open(tester);
    await tester.drag(
        find.byKey(const ValueKey('avatar-stage')), const Offset(900, 900));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('avatar-use')));
    await tester.pumpAndSettle();

    final c = crops.single;
    expect((c.x, c.y, c.side), (0, 0, 200));
  });

  testWidgets('a failed render keeps the screen open', (tester) async {
    await open(tester, fail: true);
    await tester.tap(find.byKey(const ValueKey('avatar-use')));
    await tester.pumpAndSettle();

    expect(crops, hasLength(1));
    expect(popped, isNull);
    expect(find.byKey(const ValueKey('avatar-stage')), findsOneWidget);
    expect(find.textContaining("couldn't be used"), findsOneWidget);
  });

  testWidgets('backing out returns nothing', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('avatar-back')));
    await tester.pumpAndSettle();
    expect(popped, isNull);
    expect(crops, isEmpty);
  });
}
