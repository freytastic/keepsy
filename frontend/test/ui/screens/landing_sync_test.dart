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
}
