import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/providers/upload_queue_model.dart';
import 'package:keepsy/ui/shelf/album_print.dart';
import 'package:keepsy/ui/shelf/shelf_layout.dart';
import 'package:keepsy/ui/shelf/shelf_screen.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';

import '../ui/upload_scaffold.dart';

AlbumModel _album(String id) => AlbumModel(
      id: id,
      nameCt: null,
      createdAt: DateTime(2026, 8, 1),
      updatedAt: DateTime(2026, 8, 1),
      mediaCount: 7,
      activeMemberCount: 3,
    );

Future<void> _pumpCompact(WidgetTester tester, Size screen) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final state = AppState()
    ..setAlbums([_album('a'), _album('b'), _album('c')]);
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: state),
      ChangeNotifierProvider<UploadQueueModel>.value(value: idleUploadQueue()),
    ],
    child: const MaterialApp(home: ShelfScreen()),
  ));
  await tester.pump(const Duration(milliseconds: 600));
  await tester.tap(find.byKey(const ValueKey('view-trigger')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('compact shows all three prints above the bar', (tester) async {
    const screen = Size(411, 891);
    await _pumpCompact(tester, screen);

    final prints = find.byType(AlbumPrint);
    expect(prints, findsNWidgets(3));
    for (var i = 1; i < 3; i++) {
      expect(tester.getRect(prints.at(i)).bottom,
          lessThanOrEqualTo(screen.height - 96));
    }
    final full = screen.width - Warm.pagePad * 2;
    final lead = tester.getSize(prints.first).width;
    expect(lead, greaterThanOrEqualTo(full * minLeadScale - 1));
    expect(lead, lessThan(full - 1), reason: 'this height needs the shrink');
  });

  testWidgets('a tall screen keeps the lead print full width', (tester) async {
    const screen = Size(411, 1200);
    await _pumpCompact(tester, screen);

    final full = screen.width - Warm.pagePad * 2;
    expect(tester.getSize(find.byType(AlbumPrint).first).width,
        closeTo(full, 1));
  });
}
