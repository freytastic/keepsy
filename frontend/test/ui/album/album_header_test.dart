import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/album/album_copy.dart';
import 'package:keepsy/ui/album/album_header.dart';
import 'package:keepsy/ui/album/member_avatars.dart';

void main() {
  late int cleared;

  Future<void> pump(
    WidgetTester tester, {
    String summary = '3 photos · 1.2 MB · 2 people',
    List<AvatarMember> members = const [
      AvatarMember(token: 'a', name: 'Ana'),
      AvatarMember(token: 'b', name: 'Bea'),
    ],
    String? filterToken,
    String? filterName,
    int filterCount = 0,
  }) async {
    cleared = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AlbumHeader(
          title: 'Lisbon',
          summary: summary,
          members: members,
          filterToken: filterToken,
          filterName: filterName,
          filterCount: filterCount,
          onTapMember: (_) {},
          onClearFilter: () => cleared++,
        ),
      ),
    ));
  }

  testWidgets('shows the people as avatars, with no names beside them',
      (tester) async {
    await pump(tester);

    expect(find.byType(MemberAvatars), findsOneWidget);
    expect(find.text('Ana'), findsNothing);
    expect(find.text('Bea'), findsNothing);
  });

  testWidgets('while filtering it offers a way back to everyone',
      (tester) async {
    await pump(tester, filterToken: 'a', filterName: 'Ana', filterCount: 4);

    expect(find.text(AlbumCopy.filteredBy('Ana', 4)), findsOneWidget);

    await tester.tap(find.text(AlbumCopy.filteredBy('Ana', 4)));
    await tester.pump();

    expect(cleared, 1);
  });

  group('collapsed bar', () {
    testWidgets('is invisible and untappable until the header scrolls away',
        (tester) async {
      var more = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AlbumTopBar(
            title: 'Lisbon',
            visible: false,
            onBack: () {},
            onMore: () => more++,
          ),
        ),
      ));

      await tester.tap(find.byTooltip(AlbumCopy.more), warnIfMissed: false);
      await tester.pump();

      expect(more, 0, reason: 'a hidden bar must not swallow taps');
    });

    testWidgets('keeps its controls clear of the status bar', (tester) async {
      const inset = 44.0;
      await tester.pumpWidget(const MediaQuery(
        data: MediaQueryData(padding: EdgeInsets.only(top: inset)),
        child: MaterialApp(
          home: Scaffold(
            body: AlbumTopBar(
              title: 'Lisbon',
              visible: true,
              onBack: _noop,
              onMore: _noop,
            ),
          ),
        ),
      ));

      final back = tester.getRect(find.byTooltip(AlbumCopy.back));
      expect(back.top, greaterThanOrEqualTo(inset));
      expect(
        tester.getSize(find.byType(AlbumTopBar)).height,
        AlbumTopBar.barHeight + inset,
        reason: 'the gradient still covers the status bar',
      );
    });
  });
}

void _noop() {}
