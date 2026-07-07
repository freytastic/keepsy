import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/epoch_rotator.dart';
import 'package:keepsy/e2ee/member_removal.dart';

Uint8List _album([int s = 0xA1]) => Uint8List.fromList(List<int>.filled(16, s));
Uint8List _tok(int s) => Uint8List.fromList(List<int>.filled(32, s));

// Records every port interaction so the tests can assert order + arguments
class _Ports {
  final calls = <String>[];
  bool revokeResult = true;
  List<Uint8List> active = const [];
  int current = 0;

  Uint8List? revokedToken;
  int? rotatedEpoch;
  List<RotateRecipient>? rotatedRecipients;
  Uint8List? droppedToken;
  bool wiped = false;
  bool pending = false;

  MemberRemovalCoordinator build() => MemberRemovalCoordinator(
        revoke: (album, token) async {
          calls.add('revoke');
          revokedToken = token;
          return revokeResult;
        },
        activeTokens: (album) async {
          calls.add('activeTokens');
          return active;
        },
        currentEpoch: (album) async => current,
        rotate: (album, epoch, recipients) async {
          calls.add('rotate');
          rotatedEpoch = epoch;
          rotatedRecipients = recipients;
        },
        dropDirectory: (album, token) {
          calls.add('dropDirectory');
          droppedToken = token;
        },
        wipeLocalAlbum: (album) async {
          calls.add('wipeLocalAlbum');
          wiped = true;
        },
        isPendingRotation: (album) async {
          calls.add('isPendingRotation');
          return pending;
        },
      );
}

void main() {
  group('kick', () {
    test(
        'revokes, then rotates to next epoch for the remaining members, '
        'then drops the removed token', () async {
      final p = _Ports()
        ..active = [_tok(1), _tok(2)] // admin + one remaining, post revoke
        ..current = 4;
      final target = _tok(9);

      await p.build().kick(_album(), target);

      // revoke MUST precede rotate (the server drift-check needs the removed
      // member out of the active set before the rotation is accepted)
      expect(p.calls, ['revoke', 'activeTokens', 'rotate', 'dropDirectory']);
      expect(p.revokedToken, equals(target));
      expect(p.rotatedEpoch, 5); // current + 1
      expect(p.droppedToken, equals(target));
      // recipients are by token (userId null) and cover exactly the active set
      expect(p.rotatedRecipients!.map((r) => r.userId), everyElement(isNull));
      expect(
        p.rotatedRecipients!.map((r) => r.memberToken).toList(),
        [_tok(1), _tok(2)],
      );
    });

    test('does not rotate when the revoke fails', () async {
      final p = _Ports()..revokeResult = false;
      await expectLater(
        p.build().kick(_album(), _tok(9)),
        throwsA(isA<MemberRemovalException>()),
      );
      expect(p.calls, ['revoke']);
    });
  });

  group('leave', () {
    test('revokes then wipes local album data, without rotating', () async {
      final p = _Ports();
      await p.build().leave(_album(), _tok(7));
      expect(p.calls, ['revoke', 'wipeLocalAlbum']);
      expect(p.wiped, isTrue);
      expect(p.rotatedEpoch, isNull);
    });

    test('does not wipe when the revoke fails', () async {
      final p = _Ports()..revokeResult = false;
      await expectLater(
        p.build().leave(_album(), _tok(7)),
        throwsA(isA<MemberRemovalException>()),
      );
      expect(p.calls, ['revoke']);
      expect(p.wiped, isFalse);
    });
  });

  group('ws-driven cases', () {
    test('onSelfRemoved wipes local data without any server call', () async {
      final p = _Ports();
      await p.build().onSelfRemoved(_album());
      expect(p.calls, ['wipeLocalAlbum']);
      expect(p.wiped, isTrue);
    });

    test('onOtherRemoved drops the token from the directory', () async {
      final p = _Ports();
      p.build().onOtherRemoved(_album(), _tok(9));
      expect(p.calls, ['dropDirectory']);
      expect(p.droppedToken, equals(_tok(9)));
    });
  });

  group('recoverIfPending', () {
    test('rotates for the current active set when a rotation is pending',
        () async {
      final p = _Ports()
        ..pending = true
        ..active = [_tok(1), _tok(2)]
        ..current = 6;
      final did = await p.build().recoverIfPending(_album());
      expect(did, isTrue);
      expect(p.calls, ['isPendingRotation', 'activeTokens', 'rotate']);
      expect(p.rotatedEpoch, 7);
      expect(p.rotatedRecipients!.map((r) => r.memberToken).toList(),
          [_tok(1), _tok(2)]);
    });

    test('is a no-op when nothing is pending', () async {
      final p = _Ports()..pending = false;
      final did = await p.build().recoverIfPending(_album());
      expect(did, isFalse);
      expect(p.calls, ['isPendingRotation']);
    });
  });
}
