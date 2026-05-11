import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Mirror of test/secure_store/layering_test.dart : nothing in lib/e2ee/ is
// allowed to leak raw private bytes. Allowlist scopes per file the few public
// surfaces that intentionally hand a 32B shared secret to a caller (D10 :
// caller owns the lifetime, must zero after use)
final _leakRe = RegExp(
  r'Future<[^>]*Uint8List[^>]*>\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(',
);

// X3dhSession.derive : 32B X3DH shared secret. Public per spec §5.2 / D10
// FileDecryptor.downloadAndDecrypt : decrypted plaintext file bytes. Public
// per §5.2 : the only way for the UI (EncryptedImage) to get pixels to show
// Caller (the widget's State) holds bytes in memory only : on dispose the
// State + bytes are eligible for GC. No on disk plaintext cache in §5.2
const _allow = <(String, String)>{
  ('x3dh_session.dart', 'derive'),
  ('file_decryptor.dart', 'downloadAndDecrypt'),
};

void main() {
  group('lib/e2ee layering', () {
    test('no public method outside the allowlist returns Uint8List', () {
      final dir = Directory('lib/e2ee');
      expect(dir.existsSync(), isTrue,
          reason: 'expected to run from keepsy/frontend');

      final violations = <String>[];
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        for (final m in _leakRe.allMatches(src)) {
          final name = m.group(1)!;
          if (name.startsWith('_')) continue;
          // Skip 'Function' : the regex false matches typedef declarations
          // like 'typedef X = Future<Uint8List> Function(...)' as if Function
          // were a method name. The typedef itself doesnt leak any bytes
          if (name == 'Function') continue;
          final pair = (f.uri.pathSegments.last, name);
          if (_allow.contains(pair)) continue;
          violations.add('${f.path}: public `$name` returns Uint8List');
        }
      }
      expect(violations, isEmpty,
          reason:
              'lib/e2ee/ may not leak raw bytes (allowlist is empty):\n${violations.join("\n")}');
    });

    test('lib/e2ee does not import package:keepsy/data or package:keepsy/ui',
        () {
      final dir = Directory('lib/e2ee');
      final bad = <String>[];
      final pat = RegExp(r"""import\s+['"]package:keepsy/(data|ui)/""");
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        if (pat.hasMatch(src)) bad.add(f.path);
      }
      expect(bad, isEmpty,
          reason:
              'lib/e2ee/ must stay decoupled from data/ and ui/ : got $bad');
    });
  });
}
