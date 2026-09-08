import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/album/member_avatars.dart';

void main() {
  test('normalizes a resolved initial', () {
    expect(MemberAvatars.initialFor('Ana'), 'A');
    expect(MemberAvatars.initialFor('ana'), 'A');
    expect(MemberAvatars.initialFor('  bea'), 'B');
  });

  testWidgets('an unresolved member never leaks its token', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MemberAvatars(
          members: const [
            AvatarMember(token: 'secret-token', name: null),
          ],
          onTap: (_) {},
        ),
      ),
    ));

    expect(find.textContaining('secret'), findsNothing);
    expect(find.text('·'), findsOneWidget);
  });
}
