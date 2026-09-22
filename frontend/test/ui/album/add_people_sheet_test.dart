import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/api/api_error.dart';
import 'package:keepsy/e2ee/prekey_api.dart' show HandleNotFoundException;
import 'package:keepsy/ui/album/add_people_sheet.dart';
import 'package:keepsy/ui/album/album_copy.dart';
import 'package:keepsy/ui/album/member_avatars.dart';

// The caret blinks while the field has focus, so the sheet never settles
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late bool? result;

  Future<void> open(WidgetTester tester, SendInvite onInvite) async {
    result = null;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () async => result = await AddPeopleSheet.show(
                ctx,
                albumTitle: 'Birthday',
                members: const [AvatarMember(token: 'a', name: 'Noor')],
                myKeepsyId: '7K3M9QPZ',
                onInvite: onInvite,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('add-field')), text);
    await tester.pump();
  }

  Future<void> add(WidgetTester tester) async {
    await tester.tap(find.text(AlbumCopy.addGo));
    await settle(tester);
  }

  Future<void> failsWith(WidgetTester tester, Object error, String say) async {
    await open(tester, (_) async => throw error);
    await type(tester, 'K7F29QXM');
    await add(tester);
    expect(find.text(say), findsOneWidget);
    expect(find.text(AlbumCopy.addDoneTitle), findsNothing);
  }

  testWidgets('invites with the canonical handle', (tester) async {
    String? sent;
    await open(tester, (id) async => sent = id);

    await type(tester, 'k7f2-9qxm');
    await add(tester);

    expect(sent, 'K7F29QXM');
    expect(find.text(AlbumCopy.addDoneTitle), findsOneWidget);
    expect(
        find.textContaining('K7F2-9QXM', findRichText: true), findsOneWidget);
  });

  testWidgets('folds the letters people confuse and drops the rest',
      (tester) async {
    await open(tester, (_) async {});

    await type(tester, 'ilo!u');

    expect(find.text('1'), findsNWidgets(2));
    expect(find.text('0'), findsOneWidget);
    expect(find.text('U'), findsNothing);
  });

  testWidgets('does nothing until all eight characters are in', (tester) async {
    var called = false;
    await open(tester, (_) async => called = true);

    await type(tester, 'K7F29QX');
    await add(tester);

    expect(called, isFalse);
  });

  testWidgets('refuses your own ID without a lookup', (tester) async {
    var called = false;
    await open(tester, (_) async => called = true);

    await type(tester, '7k3m-9qpz');
    await add(tester);

    expect(called, isFalse);
    expect(find.text(AlbumCopy.addSelf), findsOneWidget);
  });

  testWidgets(
      'an unknown ID says so',
      (tester) => failsWith(tester, const HandleNotFoundException('K7F29QXM'),
          AlbumCopy.addUnknown));

  testWidgets(
      'someone already in the album says so',
      (tester) => failsWith(
          tester,
          const ApiError(code: 'E_CONFLICT', message: '', httpStatus: 409),
          AlbumCopy.addAlready));

  testWidgets(
      'a full album says so',
      (tester) => failsWith(
          tester,
          const ApiError(code: 'E_ALBUM_FULL', message: '', httpStatus: 409),
          AlbumCopy.addFull));

  testWidgets(
      'a pending rotation asks to wait',
      (tester) => failsWith(
          tester,
          const ApiError(
              code: 'E_EPOCH_PENDING_ROTATION', message: '', httpStatus: 409),
          AlbumCopy.addRotating));

  testWidgets('anything else is a retry',
      (tester) => failsWith(tester, Exception('offline'), AlbumCopy.addFailed));

  testWidgets('typing again clears the error', (tester) async {
    await open(tester, (_) async => throw const HandleNotFoundException('x'));
    await type(tester, 'K7F29QXM');
    await add(tester);

    await type(tester, 'K7F2');

    expect(find.text(AlbumCopy.addUnknown), findsNothing);
  });

  testWidgets('add another starts over, done reports the invite',
      (tester) async {
    final sent = <String>[];
    await open(tester, (id) async => sent.add(id));
    await type(tester, 'K7F29QXM');
    await add(tester);

    await tester.tap(find.text(AlbumCopy.addAnother));
    await settle(tester);
    expect(find.text(AlbumCopy.addGo), findsOneWidget);
    await type(tester, 'M3NP4QRS');
    await add(tester);

    await tester.tap(find.text(AlbumCopy.addDone));
    await settle(tester);
    expect(sent, ['K7F29QXM', 'M3NP4QRS']);
    expect(result, isTrue);
  });

  testWidgets('closing without inviting reports nothing added', (tester) async {
    await open(tester, (_) async {});

    expect(await tester.binding.handlePopRoute(), isTrue);
    await settle(tester);

    expect(find.text(AlbumCopy.addTitle), findsNothing);
    expect(result, isFalse);
  });

  group('the faces row', () {
    Future<void> faces(WidgetTester tester, List<AvatarMember> members,
        {VoidCallback? onAdd, ValueChanged<String>? onTap}) {
      return tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemberAvatars(
            members: members,
            onTap: onTap ?? (_) {},
            onAdd: onAdd,
          ),
        ),
      ));
    }

    testWidgets('an invited member is a dashed place with no filter',
        (tester) async {
      final tapped = <String>[];
      await faces(
          tester,
          const [
            AvatarMember(token: 'a', name: 'Noor'),
            AvatarMember(token: 'b', pending: true),
          ],
          onTap: tapped.add);

      expect(find.byType(DashedCircle), findsOneWidget);
      await tester.tap(find.byType(DashedCircle));
      expect(tapped, isEmpty);
    });

    testWidgets('the add button shows only when offered', (tester) async {
      var added = 0;
      await faces(tester, const [AvatarMember(token: 'a')]);
      expect(find.byKey(const ValueKey('add-someone')), findsNothing);

      await faces(tester, const [AvatarMember(token: 'a')],
          onAdd: () => added++);
      await tester.tap(find.byKey(const ValueKey('add-someone')));
      await settle(tester);
      expect(added, 1);
    });
  });
}
