import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/screens/landing_screen.dart';

Uint8List _id(int fill) => Uint8List(16)..fillRange(0, 16, fill);

void main() {
  test('syncAlbumKeys clears the syncing flag after catch-up succeeds',
      () async {
    final appState = AppState();
    final ids = [_id(0xAB)];
    await syncAlbumKeys(
      appState: appState,
      albumIds: ids,
      catchUp: (_) async {},
    );
    expect(appState.isSyncing(uuidStringFromBytes(ids.first)), isFalse);
  });

  test('syncAlbumKeys clears the syncing flag even when catch-up throws',
      () async {
    // The original bug : cleanup was gated on the (unmounted) screen, so a
    // failure or a screen teardown left the overlay stuck forever
    final appState = AppState();
    final ids = [_id(0xCD)];
    await syncAlbumKeys(
      appState: appState,
      albumIds: ids,
      catchUp: (_) async => throw StateError('boom'),
    );
    expect(appState.isSyncing(uuidStringFromBytes(ids.first)), isFalse);
  });

  test('syncAlbumKeys marks syncing while catch-up is in flight', () async {
    final appState = AppState();
    final ids = [_id(0x11)];
    final idStr = uuidStringFromBytes(ids.first);
    bool seenDuring = false;
    await syncAlbumKeys(
      appState: appState,
      albumIds: ids,
      catchUp: (_) async {
        seenDuring = appState.isSyncing(idStr);
      },
    );
    expect(seenDuring, isTrue);
    expect(appState.isSyncing(idStr), isFalse);
  });

  test('a slow album does not hold the others in syncing', () async {
    final appState = AppState();
    final slow = _id(0x01);
    final fast = _id(0x02);
    final slowGate = Completer<void>();

    final done = syncAlbumKeys(
      appState: appState,
      albumIds: [slow, fast],
      catchUp: (batch) async {
        expect(batch, hasLength(1));
        if (batch.first[0] == 0x01) await slowGate.future;
      },
    );

    await pumpEventQueue();
    expect(appState.isSyncing(uuidStringFromBytes(fast)), isFalse,
        reason: 'the fast album must clear while the slow one is in flight');
    expect(appState.isSyncing(uuidStringFromBytes(slow)), isTrue);

    slowGate.complete();
    await done;
    expect(appState.isSyncing(uuidStringFromBytes(slow)), isFalse);
  });

  test('one album failing does not skip remaining albums', () async {
    final appState = AppState();
    final bad = _id(0x03);
    final good = _id(0x04);
    final tail = _id(0x05);
    final processed = <int>[];

    await syncAlbumKeys(
      appState: appState,
      albumIds: [bad, good, tail],
      catchUp: (batch) async {
        processed.add(batch.first[0]);
        if (batch.first[0] == 0x03) throw StateError('boom');
      },
    );

    expect(processed, containsAll(<int>[0x03, 0x04, 0x05]));
    expect(appState.isSyncing(uuidStringFromBytes(bad)), isFalse);
    expect(appState.isSyncing(uuidStringFromBytes(good)), isFalse);
    expect(appState.isSyncing(uuidStringFromBytes(tail)), isFalse);
  });
}
