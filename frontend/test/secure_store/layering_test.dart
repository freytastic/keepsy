import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Boundary contract: lib/secure_store/ is the only place raw private bytes
// surface from a public API. Public methods returning Uint8List (or any
// Future<...Uint8List...>) must be on the allowlist below : everything else
// MUST hand callers an opaque KeyHandle or run inside a use<T> callback
final _leakRe = RegExp(
  r'Future<[^>]*Uint8List[^>]*>\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(',
);

const _allow = <(String, String)>{
  ('secure_key_store.dart', 'getOnce'),
  ('android_keystore.dart', 'getOnce'),
  ('ios_secure_enclave.dart', 'getOnce'),
  ('key_handle_adapter.dart', 'toEd25519'),
  ('key_handle_adapter.dart', 'toX25519'),
};

void main() {
  group('lib/secure_store layering', () {
    test('no public method outside the allowlist returns Uint8List', () {
      final dir = Directory('lib/secure_store');
      expect(dir.existsSync(), isTrue,
          reason: 'expected to run from keepsy/frontend');

      final violations = <String>[];
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        for (final m in _leakRe.allMatches(src)) {
          final name = m.group(1)!;
          if (name.startsWith('_')) continue;
          final pair = (f.uri.pathSegments.last, name);
          if (_allow.contains(pair)) continue;
          violations.add('${f.path}: public `$name` returns Uint8List');
        }
      }
      expect(violations, isEmpty,
          reason:
              'lib/secure_store/ may not leak raw bytes outside the allowlist:\n${violations.join("\n")}');
    });

    test('regex catches a synthetic violation in an inline source sample', () {
      // Fake source string standing in for a hypothetical leak , proves the
      // regex matches without needing to mutate real files (delta from plan)
      const sample =
          "class Bad { Future<Uint8List> evilLeak() async => Uint8List(0); }";
      final m = _leakRe.firstMatch(sample);
      expect(m, isNotNull);
      expect(m!.group(1), 'evilLeak');
      // And verify the allowlist tuple membership check rejects it
      final pair = ('secure_key_store.dart', 'evilLeak');
      expect(_allow.contains(pair), isFalse);
    });

    test('regex ignores private methods', () {
      const sample = "Future<Uint8List> _internalCopy() async => Uint8List(0);";
      final name = _leakRe.firstMatch(sample)!.group(1)!;
      expect(name.startsWith('_'), isTrue);
    });
  });
}
