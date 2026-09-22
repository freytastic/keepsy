import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/domain/activity/activity_event.dart';
import 'package:keepsy/domain/activity/trust_alarm.dart';

void main() {
  final ik = Uint8List.fromList(List.filled(32, 9));

  // A key change is the one event that most needs attention: the dot must
  // light, and only after the row exists to be seen
  test('the dot lights only after the alarm is written', () async {
    final order = <String>[];
    await recordTrustAlarm(
      record: (events) async {
        await Future<void>.delayed(Duration.zero);
        order.add('record');
        final e = events.single as SafetyNumberChanged;
        expect(e.presentedIk, ik);
        expect(e.peerToken, 'noor');
      },
      onRecorded: () async => order.add('dot'),
      albumId: 'album-1',
      memberToken: 'noor',
      newIkPub: ik,
      now: DateTime.utc(2026, 9, 22),
    );

    expect(order, ['record', 'dot']);
  });

  // A later, different key must alarm again rather than read as a duplicate
  test('the id is keyed on the new key', () async {
    final ids = <String>[];
    for (final k in [ik, Uint8List.fromList(List.filled(32, 3))]) {
      await recordTrustAlarm(
        record: (events) async => ids.add(events.single.id),
        onRecorded: () async {},
        albumId: 'album-1',
        memberToken: 'noor',
        newIkPub: k,
        now: DateTime.utc(2026, 9, 22),
      );
    }
    expect(ids.toSet(), hasLength(2));
  });

  test('a failed write does not light the dot or throw', () async {
    var lit = false;
    await recordTrustAlarm(
      record: (_) async => throw StateError('disk'),
      onRecorded: () async => lit = true,
      albumId: 'album-1',
      memberToken: 'noor',
      newIkPub: ik,
      now: DateTime.utc(2026, 9, 22),
    );
    expect(lit, isFalse);
  });
}
