import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/epoch_processor.dart';
import 'package:keepsy/ui/providers/app_state.dart';

void main() {
  late AppState state;
  late List<String> resumed;

  setUp(() {
    state = AppState();
    resumed = [];
    state.attachUploadResume(resumed.add);
  });

  test('a successful sync releases an album that was never blocked', () {
    state.clearKeyBlock('album-1', 4);
    expect(resumed, ['album-1']);
  });

  test('clearing a real block also releases', () {
    state.setKeyBlock(
        'album-1',
        EpochBlocked(
          albumId: Uint8List(16),
          epoch: 3,
          reason: EpochBlockReason.values.first,
        ));
    state.clearKeyBlock('album-1', 3);
    expect(resumed, contains('album-1'));
  });

  test('a delayed older epoch does not release an album still blocked', () {
    state.setKeyBlock(
        'album-1',
        EpochBlocked(
          albumId: Uint8List(16),
          epoch: 5,
          reason: EpochBlockReason.values.first,
        ));
    state.clearKeyBlock('album-1', 4);
    expect(resumed, isEmpty);
    expect(state.keyBlockFor('album-1'), isNotNull);

    state.clearKeyBlock('album-1', 5);
    expect(resumed, ['album-1']);
  });

  test('a sync that finished without installing anything releases nothing', () {
    state.markSyncing(['album-1']);
    state.clearSyncing('album-1');
    expect(resumed, isEmpty);
  });

  test('a bulk sync clear releases nothing on its own', () {
    state.markSyncing(['album-1', 'album-2']);
    state.clearAllSyncing();
    expect(resumed, isEmpty);
  });

  test('the album resumes when its epoch actually installs', () {
    state.markSyncing(['album-1']);
    state.clearSyncing('album-1');
    expect(resumed, isEmpty);
    state.clearKeyBlock('album-1', 7);
    expect(resumed, ['album-1']);
  });
}
