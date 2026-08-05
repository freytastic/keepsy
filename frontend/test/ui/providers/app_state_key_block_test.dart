import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/epoch_processor.dart';
import 'package:keepsy/ui/providers/app_state.dart';

Uint8List _album([int s = 0xA1]) => Uint8List.fromList(List<int>.filled(16, s));
Uint8List _b(int s) => Uint8List.fromList(List<int>.filled(32, s));

EpochBlocked _blocked({
  EpochBlockReason reason = EpochBlockReason.signerMismatch,
  int epoch = 3,
}) =>
    EpochBlocked(
      albumId: _album(),
      epoch: epoch,
      reason: reason,
      senderToken: _b(2),
      presentedIk: _b(0x22),
    );

const _albumIdStr = 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1';

void main() {
  test('a blocked album exposes the reason and the presented key', () {
    final s = AppState();

    s.setKeyBlock(_albumIdStr, _blocked());

    final b = s.keyBlockFor(_albumIdStr)!;
    expect(b.reason, EpochBlockReason.signerMismatch);
    expect(b.epoch, 3);
    expect(b.presentedIk, equals(_b(0x22)));
  });

  test('clearing is keyed per album and leaves the others blocked', () {
    final s = AppState();
    s.setKeyBlock(_albumIdStr, _blocked());
    s.setKeyBlock('other', _blocked());

    s.clearKeyBlock(_albumIdStr, 3);

    expect(s.keyBlockFor(_albumIdStr), isNull);
    expect(s.keyBlockFor('other'), isNotNull);
  });

  // Epoch 5 fails and blocks; a delayed duplicate for epoch 4 then succeeds
  // trivially (everything through 4 is already installed) and reports itself
  // caught up. It has not reached 5, so the block must stand
  test('an older successful sync cannot clear a newer block', () {
    final s = AppState();
    s.setKeyBlock(_albumIdStr, _blocked(epoch: 5));

    s.clearKeyBlock(_albumIdStr, 4);

    expect(s.keyBlockFor(_albumIdStr), isNotNull);
  });

  test('reaching the blocked epoch clears it', () {
    final s = AppState();
    s.setKeyBlock(_albumIdStr, _blocked(epoch: 5));

    s.clearKeyBlock(_albumIdStr, 5);

    expect(s.keyBlockFor(_albumIdStr), isNull);
  });

  test('a block notifies listeners so an open album can react', () {
    final s = AppState();
    var pings = 0;
    s.addListener(() => pings++);

    s.setKeyBlock(_albumIdStr, _blocked());

    expect(pings, 1);
  });

  test('clearing an album that was never blocked notifies nobody', () {
    // unblocked fires after every successful sync, so the common case must not
    // rebuild the whole tree
    final s = AppState();
    var pings = 0;
    s.addListener(() => pings++);

    s.clearKeyBlock(_albumIdStr, 9);

    expect(pings, 0);
  });

  test('removing an album drops its key block', () {
    // revoke / leave / delete wipes the album, so a leftover block would keep
    // describing something the user no longer has
    final s = AppState();
    s.setKeyBlock(_albumIdStr, _blocked());

    s.removeAlbum(_albumIdStr);

    expect(s.keyBlockFor(_albumIdStr), isNull);
  });

  // The creator's own rotation fans back to them, so _installEpoch can run for
  // their own token before the album has landed in the albums list. Without a
  // registered self token that wrap takes the peer path and gets refused
  test('a self member token is resolvable before the album list arrives', () {
    final s = AppState();

    s.registerSelfToken(_albumIdStr, 'bXl0b2tlbg==');

    expect(s.selfMemberToken(_albumIdStr), 'bXl0b2tlbg==');
  });

  test('removing an album drops its self token', () {
    final s = AppState();
    s.registerSelfToken(_albumIdStr, 'bXl0b2tlbg==');

    s.removeAlbum(_albumIdStr);

    expect(s.selfMemberToken(_albumIdStr), isNull);
  });

  test('reset drops self tokens with the rest of the session', () {
    final s = AppState();
    s.registerSelfToken(_albumIdStr, 'bXl0b2tlbg==');

    s.reset();

    expect(s.selfMemberToken(_albumIdStr), isNull);
  });

  test('reset drops key blocks with the rest of the session', () {
    final s = AppState();
    s.setKeyBlock(_albumIdStr, _blocked());

    s.reset();

    expect(s.keyBlockFor(_albumIdStr), isNull);
  });
}
