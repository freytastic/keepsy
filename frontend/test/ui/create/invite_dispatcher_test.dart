import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/create/invite_dispatcher.dart';

void main() {
  test('sends one invite per id, in the order given', () async {
    final sent = <String>[];
    final dispatcher = InviteDispatcher((id) async => sent.add(id));

    final failed = await dispatcher.sendAll(['AAAA1111', 'BBBB2222']);

    expect(sent, ['AAAA1111', 'BBBB2222']);
    expect(failed, 0);
  });

  test('sends one at a time so keystore work does not overlap', () async {
    var inFlight = 0;
    var maxInFlight = 0;
    final dispatcher = InviteDispatcher((id) async {
      inFlight++;
      maxInFlight = maxInFlight < inFlight ? inFlight : maxInFlight;
      await Future<void>.delayed(Duration.zero);
      inFlight--;
    });

    await dispatcher.sendAll(['AAAA1111', 'BBBB2222', 'CCCC3333']);

    expect(maxInFlight, 1);
  });

  test('one failure does not stop the rest', () async {
    final sent = <String>[];
    final dispatcher = InviteDispatcher((id) async {
      if (id == 'BBBB2222') throw StateError('unknown handle');
      sent.add(id);
    });

    final failed =
        await dispatcher.sendAll(['AAAA1111', 'BBBB2222', 'CCCC3333']);

    expect(sent, ['AAAA1111', 'CCCC3333']);
    expect(failed, 1);
  });
}
