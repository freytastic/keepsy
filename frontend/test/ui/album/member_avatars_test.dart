import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/album/album_copy.dart';
import 'package:keepsy/ui/album/member_avatars.dart';

const _crowd = [
  AvatarMember(token: 't0', name: 'Ana', self: true),
  AvatarMember(token: 't1', name: 'Bea'),
  AvatarMember(token: 't2', name: 'Cai'),
  AvatarMember(token: 't3', name: 'Dov'),
  AvatarMember(token: 't4', name: 'Eli'),
  AvatarMember(token: 't5', name: 'Fay'),
  AvatarMember(token: 't6', pending: true),
];

Future<void> _pump(
  WidgetTester tester, {
  List<AvatarMember> members = _crowd,
  String? selected,
  ValueChanged<String>? onTap,
  bool folded = false,
}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            const SizedBox(key: ValueKey('outside'), height: 80, width: 300),
            MemberAvatars(
              members: members,
              selectedToken: selected,
              onTap: onTap ?? (_) {},
              onAdd: () {},
              folded: folded,
            ),
          ],
        ),
      ),
    ));

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('people-stack')));
  await tester.pumpAndSettle();
}

// Names render only in the open row
bool _isOpen(WidgetTester tester) => find.text('Bea').evaluate().isNotEmpty;

void main() {
  test('normalizes a resolved initial', () {
    expect(MemberAvatars.initialFor('Ana'), 'A');
    expect(MemberAvatars.initialFor('ana'), 'A');
    expect(MemberAvatars.initialFor('  bea'), 'B');
  });

  testWidgets('an unresolved member never leaks its token', (tester) async {
    await _pump(tester, members: const [AvatarMember(token: 'secret-token')]);
    await _open(tester);

    expect(find.textContaining('secret'), findsNothing);
    expect(find.text('·'), findsOneWidget);
    expect(find.text(AlbumCopy.unknownMember), findsOneWidget);
  });

  testWidgets('rests as four faces and a count, with no names', (tester) async {
    await _pump(tester);

    expect(find.text('+2'), findsOneWidget);
    expect(_isOpen(tester), isFalse);
  });

  testWidgets('a tap spreads everyone into a named row that filters',
      (tester) async {
    final tapped = <String>[];
    await _pump(tester, onTap: tapped.add);
    await _open(tester);

    expect(_isOpen(tester), isTrue);
    expect(find.text(AlbumCopy.you), findsOneWidget);
    expect(find.text(AlbumCopy.invitedShort), findsOneWidget);
    expect(find.text(AlbumCopy.addShort), findsOneWidget);

    await tester.tap(find.text('Cai'));
    expect(tapped, ['t2']);
  });

  testWidgets('no two open faces overlap', (tester) async {
    await _pump(tester);
    await _open(tester);

    final rects = [
      for (final name in ['Bea', 'Cai', 'Dov'])
        tester.getRect(find
            .ancestor(of: find.text(name), matching: find.byType(Column))
            .first),
    ];
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i].left, greaterThan(rects[i - 1].right));
    }
  });

  testWidgets('folds on an outside tap and when the header scrolls away',
      (tester) async {
    await _pump(tester);
    await _open(tester);
    await tester.tap(find.byKey(const ValueKey('outside')));
    await tester.pumpAndSettle();
    expect(_isOpen(tester), isFalse);

    await _open(tester);
    await _pump(tester, folded: true);
    await tester.pumpAndSettle();
    expect(_isOpen(tester), isFalse);
  });

  testWidgets('a closed stack is one target and filters nothing',
      (tester) async {
    final tapped = <String>[];
    await _pump(tester, onTap: tapped.add);
    await tester.tap(find.byKey(const ValueKey('people-stack')));
    await tester.pumpAndSettle();
    expect(tapped, isEmpty);
    expect(_isOpen(tester), isTrue);
  });
}
