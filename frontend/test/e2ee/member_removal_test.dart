import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/epoch_rotator.dart';
import 'package:keepsy/e2ee/expected_ik_resolver.dart';
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
  // A committed rotation settles the debt, as the server would report
  bool rotateClearsPending = true;
  Object? rotateError;
  // Another rotation commits while ours is failing
  bool winnerCommits = false;
  Completer<void>? rotateGate;
  int rotations = 0;

  // expected IK resolver knobs : by default maps token seed s -> ik seed s|0x80
  // so each recipient's expectedIk is distinguishable. Flip expectedIkThrows to
  // exercise the fail closed (missing pin) path
  bool expectedIkThrows = false;
  Uint8List _ikFor(Uint8List token) =>
      Uint8List.fromList(List<int>.filled(32, token[0] | 0x80));

  MemberRemovalCoordinator build() => MemberRemovalCoordinator(
        revoke: (album, token) async {
          calls.add('revoke');
          revokedToken = token;
          if (revokeResult) pending = true;
          return revokeResult;
        },
        activeTokens: (album) async {
          calls.add('activeTokens');
          return active;
        },
        currentEpoch: (album) async => current,
        rotate: (album, epoch, recipients) async {
          calls.add('rotate');
          rotations++;
          final gate = rotateGate;
          if (gate != null) await gate.future;
          final err = rotateError;
          if (err != null) {
            if (winnerCommits) pending = false;
            throw err;
          }
          rotatedEpoch = epoch;
          rotatedRecipients = recipients;
          if (rotateClearsPending) pending = false;
        },
        expectedIk: (album, token) async {
          calls.add('expectedIk');
          if (expectedIkThrows) throw MissingIdentityPinException(token);
          return _ikFor(token);
        },
        dropDirectory: (album, token) {
          calls.add('dropDirectory');
          droppedToken = token;
        },
        wipeLocalAlbum: (album) async {
          calls.add('wipeLocalAlbum');
          wiped = true;
        },
        isRotationRequired: (album) async {
          calls.add('isRotationRequired');
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
      expect(p.calls, [
        'revoke',
        'isRotationRequired',
        'activeTokens',
        'expectedIk',
        'expectedIk',
        'rotate',
        'dropDirectory'
      ]);
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

    test('binds each recipient to the resolved expected IK', () async {
      final p = _Ports()
        ..active = [_tok(1), _tok(2)]
        ..current = 4;

      await p.build().kick(_album(), _tok(9));

      final recips = p.rotatedRecipients!;
      expect(recips.map((r) => r.memberToken).toList(), [_tok(1), _tok(2)]);
      // the exact key the resolver returned for that token, not a placeholder
      expect(recips[0].expectedIk, equals(p._ikFor(_tok(1))));
      expect(recips[1].expectedIk, equals(p._ikFor(_tok(2))));
    });

    test('fails closed (never rotates) when the expected IK cannot be resolved',
        () async {
      final p = _Ports()
        ..active = [_tok(1)]
        ..current = 4
        ..expectedIkThrows = true;

      await expectLater(
        p.build().kick(_album(), _tok(9)),
        throwsA(isA<MissingIdentityPinException>()),
      );
      // resolver was reached, but no MK was ever minted or shipped
      expect(p.calls, [
        'revoke',
        'isRotationRequired',
        'activeTokens',
        'expectedIk',
        'isRotationRequired'
      ]);
      expect(p.rotatedRecipients, isNull);
    });

    test('skips its own rotation when an earlier one already settled the debt',
        () async {
      final p = _Ports()..active = [_tok(1)];
      final coord = p.build();
      final gate = p.rotateGate = Completer<void>();

      // A background recovery for an earlier departure is mid rotation
      p.pending = true;
      final background = coord.recoverIfPending(_album());
      await Future<void>.delayed(Duration.zero);
      final kick = coord.kick(_album(), _tok(9));
      await Future<void>.delayed(Duration.zero);
      // The kick's rotation waits behind the one in flight
      expect(p.rotations, 1);

      gate.complete();
      await background;
      await kick;
      expect(p.rotations, 1,
          reason: 'the queued call re checks and finds nothing owed');
      expect(p.calls.last, 'dropDirectory');
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
      expect(p.calls, [
        'isRotationRequired',
        'activeTokens',
        'expectedIk',
        'expectedIk',
        'rotate'
      ]);
      expect(p.rotatedEpoch, 7);
      expect(p.rotatedRecipients!.map((r) => r.memberToken).toList(),
          [_tok(1), _tok(2)]);
    });

    test('is a no-op when nothing is pending', () async {
      final p = _Ports()..pending = false;
      final did = await p.build().recoverIfPending(_album());
      expect(did, isFalse);
      expect(p.calls, ['isRotationRequired']);
    });

    test('losing the epoch race to another rotation counts as settled',
        () async {
      final p = _Ports()
        ..pending = true
        ..active = [_tok(1)]
        ..rotateError = Exception('epoch replay')
        ..winnerCommits = true;

      final did = await p.build().recoverIfPending(_album());

      expect(did, isFalse);
      expect(p.calls.last, 'isRotationRequired');
    });

    test('a failed rotation that is still owed propagates', () async {
      final p = _Ports()
        ..pending = true
        ..active = [_tok(1)]
        ..rotateError = Exception('network');

      await expectLater(
        p.build().recoverIfPending(_album()),
        throwsA(isA<Exception>()),
      );
      expect(p.calls, [
        'isRotationRequired',
        'activeTokens',
        'expectedIk',
        'rotate',
        'isRotationRequired'
      ]);
    });

    test('concurrent calls for one album never rotate twice', () async {
      final p = _Ports()
        ..pending = true
        ..active = [_tok(1)];
      final coord = p.build();
      final gate = p.rotateGate = Completer<void>();

      final first = coord.recoverIfPending(_album());
      final second = coord.recoverIfPending(_album());
      await Future<void>.delayed(Duration.zero);
      expect(p.rotations, 1);

      gate.complete();
      expect(await first, isTrue);
      expect(await second, isFalse);
      expect(p.rotations, 1);
    });

    test('different albums rotate independently', () async {
      final p = _Ports()
        ..pending = true
        ..active = [_tok(1)];
      final coord = p.build();
      final gate = p.rotateGate = Completer<void>();
      p.rotateClearsPending = false;

      final a = coord.recoverIfPending(_album(0xA1));
      final b = coord.recoverIfPending(_album(0xB2));
      await Future<void>.delayed(Duration.zero);
      expect(p.rotations, 2, reason: 'album B must not wait on album A');

      gate.complete();
      await Future.wait([a, b]);
    });
  });
}
