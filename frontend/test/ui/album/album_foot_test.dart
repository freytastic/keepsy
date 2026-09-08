import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/album/album_copy.dart';
import 'package:keepsy/ui/album/album_foot.dart';
import 'package:keepsy/ui/widgets/foot_bar.dart';

void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            const SizedBox.expand(child: ColoredBox(color: Colors.white)),
            AlbumFoot(
              onSelect: () {},
              onAdd: () {},
              onDownload: () {},
              pill: const Text('pill'),
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('offers select, add and download, in the mock order',
      (tester) async {
    await pump(tester);

    final select = tester.getCenter(find.text(AlbumCopy.select));
    final add = tester.getCenter(find.byType(MakeButton));
    final download = tester.getCenter(find.text(AlbumCopy.download));

    expect(select.dx, lessThan(add.dx));
    expect(add.dx, lessThan(download.dx));
  });

  testWidgets('the upload pill sits clear of the add button', (tester) async {
    await pump(tester);

    expect(tester.getRect(find.text('pill')).bottom,
        lessThanOrEqualTo(tester.getRect(find.byType(MakeButton)).top));
  });
}
