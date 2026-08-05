import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/expected_ik_resolver.dart';

Uint8List _album([int s = 0xA1]) => Uint8List.fromList(List<int>.filled(16, s));
Uint8List _tok(int s) => Uint8List.fromList(List<int>.filled(32, s));
Uint8List _ik(int s) => Uint8List.fromList(List<int>.filled(32, s));

void main() {
  test('the local member token resolves to currentIkPub, never a pin',
      () async {
    final selfIk = _ik(0x11);
    var pinConsulted = false;
    final resolver = ExpectedIkResolver(
      selfToken: (_) => _tok(1),
      pinned: (_, __) {
        pinConsulted = true;
        return _ik(0x99); // must be ignored for self
      },
      currentIk: () async => selfIk,
    );

    final got = await resolver(_album(), _tok(1));
    expect(got, equals(selfIk));
    expect(pinConsulted, isFalse);
  });

  test('a non-self member with a pin resolves to the pinned IK', () async {
    final pinned = _ik(0x22);
    final resolver = ExpectedIkResolver(
      selfToken: (_) => _tok(1),
      pinned: (_, token) => _bytesEqual(token, _tok(2)) ? pinned : null,
      currentIk: () async => _ik(0x11),
    );

    final got = await resolver(_album(), _tok(2));
    expect(got, equals(pinned));
  });

  test('a non-self member without a pin fails closed', () async {
    final resolver = ExpectedIkResolver(
      selfToken: (_) => _tok(1),
      pinned: (_, __) => null,
      currentIk: () async => _ik(0x11),
    );

    await expectLater(
      resolver(_album(), _tok(2)),
      throwsA(isA<MissingIdentityPinException>()),
    );
  });

  group('signer gate (responder side)', () {
    // Mutable signer bindings let tests assert what the gate persisted
    ({
      ExpectedIkResolver resolver,
      Map<String, Uint8List> pins,
      List<String> writes,
    }) build({
      Uint8List? selfToken,
      Uint8List? selfIk,
      bool soleSigner = false,
    }) {
      final pins = <String, Uint8List>{};
      final writes = <String>[];
      final resolver = ExpectedIkResolver.responder(
        selfToken: (_) => selfToken,
        pinned: (_, __) => null, // roster identity is call()'s concern
        signerPinned: (_, token) => pins[_key(token)],
        currentIk: () async => selfIk ?? _ik(0x11),
        soleSigner: (_) => soleSigner,
        pin: (_, token, ik) async {
          pins[_key(token)] = ik;
          writes.add(_key(token));
        },
      );
      return (resolver: resolver, pins: pins, writes: writes);
    }

    test('our own token is checked against the local IK', () async {
      final f = build(selfToken: _tok(1), selfIk: _ik(0x11));

      final t = await f.resolver
          .check(_album(), _tok(1), _ik(0x11), allowTofu: false);

      expect(t, SignerTrust.pinned);
      expect(f.pins, isEmpty, reason: 'we deliberately never pin ourselves');
    });

    test('a server claiming a different IK for our own token fails closed',
        () async {
      final f = build(selfToken: _tok(1), selfIk: _ik(0x11));

      await expectLater(
        f.resolver.check(_album(), _tok(1), _ik(0x99), allowTofu: true),
        throwsA(isA<IdentitySignerMismatchException>()
            .having((e) => e.isSelf, 'isSelf', isTrue)),
      );
    });

    test('checking never writes a pin on its own', () async {
      // The signature has not been verified at check() time, so a server could
      // otherwise poison the pin with a key it does not even hold
      final f = build(selfToken: _tok(1));

      final t =
          await f.resolver.check(_album(), _tok(2), _ik(0x22), allowTofu: true);

      expect(t, SignerTrust.firstSight);
      expect(f.pins, isEmpty);
      expect(f.writes, isEmpty);
    });

    test('adopt persists the first sight baseline', () async {
      final f = build(selfToken: _tok(1));

      await f.resolver.adopt(_album(), _tok(2), _ik(0x22));

      expect(f.pins[_key(_tok(2))], equals(_ik(0x22)));
    });

    test('a presented key matching the pin is trusted without a write',
        () async {
      final f = build(selfToken: _tok(1));
      f.pins[_key(_tok(2))] = _ik(0x22);

      final t = await f.resolver
          .check(_album(), _tok(2), _ik(0x22), allowTofu: false);

      expect(t, SignerTrust.pinned);
      expect(f.writes, isEmpty);
    });

    test('a presented key contradicting the pin fails closed and keeps the pin',
        () async {
      final f = build(selfToken: _tok(1));
      f.pins[_key(_tok(2))] = _ik(0x22);

      await expectLater(
        f.resolver.check(_album(), _tok(2), _ik(0x33), allowTofu: true),
        throwsA(isA<IdentitySignerMismatchException>()
            .having((e) => e.isSelf, 'isSelf', isFalse)
            .having((e) => e.presentedIk, 'presentedIk', equals(_ik(0x33)))),
      );
      expect(f.pins[_key(_tok(2))], equals(_ik(0x22)));
    });

    // Without this, a server just invents a NEW sender_token, supplies its own
    // IK, and gets it adopted as an innocent first sight : the original
    // MK injection with no existing pin disturbed
    test('an unknown signer on an established album is refused', () async {
      final f = build(selfToken: _tok(1));

      await expectLater(
        f.resolver.check(_album(), _tok(9), _ik(0x99), allowTofu: false),
        throwsA(isA<UnknownSignerException>()
            .having((e) => e.presentedIk, 'presentedIk', equals(_ik(0x99)))),
      );
      expect(f.pins, isEmpty);
    });

    // There is no "verified elsewhere" shortcut: verification is not bound to a
    // member token, so it cannot authorize that token to sign
    test('a verified key elsewhere does not excuse a pin mismatch', () async {
      final f = build(selfToken: _tok(1));
      f.pins[_key(_tok(2))] = _ik(0x22);

      await expectLater(
        f.resolver.check(_album(), _tok(2), _ik(0x33), allowTofu: true),
        throwsA(isA<IdentitySignerMismatchException>()),
      );
    });

    // An album this device created has no epoch yet, so nobody else can
    // legitimately have signed one. Zero MKs must not mean open season
    test('while awaiting our own epoch 0 no peer token may sign', () async {
      final f = build(selfToken: _tok(1), soleSigner: true);

      await expectLater(
        f.resolver.check(_album(), _tok(2), _ik(0x22), allowTofu: true),
        throwsA(isA<UnknownSignerException>()),
      );
      expect(f.pins, isEmpty);
    });

    test('while awaiting our own epoch 0 our own token still signs', () async {
      final f = build(selfToken: _tok(1), selfIk: _ik(0x11), soleSigner: true);

      final t =
          await f.resolver.check(_album(), _tok(1), _ik(0x11), allowTofu: true);

      expect(t, SignerTrust.pinned);
    });

    // The rule while awaiting epoch 0 is literal: self signs, everyone else is
    // refused. A binding that predates the album must not create an exception
    test('while awaiting epoch 0 even a bound peer is refused', () async {
      final f = build(selfToken: _tok(1), soleSigner: true);
      f.pins[_key(_tok(2))] = _ik(0x22);

      await expectLater(
        f.resolver.check(_album(), _tok(2), _ik(0x22), allowTofu: true),
        throwsA(isA<UnknownSignerException>()),
      );
    });

    // A crash after epoch 0 installed but before the marker was cleared must
    // not block the album forever : with keys present the rule goes inert
    test('a stale creating marker is inert once the album has keys', () async {
      final f = build(selfToken: _tok(1), soleSigner: true);
      f.pins[_key(_tok(2))] = _ik(0x22);

      final t = await f.resolver
          .check(_album(), _tok(2), _ik(0x22), allowTofu: false);

      expect(t, SignerTrust.pinned);
    });

    test('the initiator constructor refuses to run the gate', () async {
      // No signer ports : it must throw rather than quietly reuse the roster pin
      final resolver = ExpectedIkResolver(
        selfToken: (_) => _tok(1),
        pinned: (_, __) => _ik(0x22),
        currentIk: () async => _ik(0x11),
      );

      await expectLater(
        resolver.check(_album(), _tok(2), _ik(0x22), allowTofu: false),
        throwsA(isA<StateError>()),
      );
    });

    test('adopt leaves an identical binding written meanwhile alone', () async {
      final f = build(selfToken: _tok(1));
      f.pins[_key(_tok(2))] = _ik(0x22);

      await f.resolver.adopt(_album(), _tok(2), _ik(0x22));

      expect(f.writes, isEmpty);
    });

    // markVerified can land between check() and the signature verification that
    // precedes adopt(). Whatever it established must win
    test('adopt refuses to overwrite a binding that appeared meanwhile',
        () async {
      final f = build(selfToken: _tok(1));
      f.pins[_key(_tok(2))] = _ik(0x33);

      await expectLater(
        f.resolver.adopt(_album(), _tok(2), _ik(0x22)),
        throwsA(isA<IdentitySignerMismatchException>()),
      );
      expect(f.pins[_key(_tok(2))], equals(_ik(0x33)));
    });
  });
}

String _key(Uint8List b) => b.map((x) => x.toRadixString(16)).join();

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
