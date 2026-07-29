import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/expected_ik_resolver.dart';

Uint8List _album([int s = 0xA1]) => Uint8List.fromList(List<int>.filled(16, s));
Uint8List _tok(int s) => Uint8List.fromList(List<int>.filled(32, s));
Uint8List _ik(int s) => Uint8List.fromList(List<int>.filled(32, s));

void main() {
  test('the local member token resolves to currentIkPub, never a pin', () async {
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
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
