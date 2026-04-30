// see lib/crypto/README.md and lib/domain/README.md.

// crypto/ and domain/ must stay pure Dart so they're testable, reviewable,
// and protected from accidental UI churn. ui/ must not reach into crypto/
// directly, it has to go through domain/ so the use cases stay the only
// surface the screens know about

// If you hit this test, the fix is almost always to move the offending
// helper into the right layer.

import 'dart:io';
import 'package:test/test.dart';

const _libRoot = 'lib';

final _flutterImport = RegExp(r"""import\s+['"]package:flutter/""");
final _cryptoImport =
    RegExp(r"""import\s+['"](?:package:keepsy/crypto/|\.\./crypto/|crypto/)""");

void main() {
  group('layering', () {
    test('crypto/ contains no Flutter imports', () {
      final offenders = _scanForFlutterImports('$_libRoot/crypto');
      expect(
        offenders,
        isEmpty,
        reason: 'lib/crypto must be pure Dart. Move Flutter widgets to lib/ui.',
      );
    });

    test('domain/ contains no Flutter imports', () {
      final offenders = _scanForFlutterImports('$_libRoot/domain');
      expect(
        offenders,
        isEmpty,
        reason: 'lib/domain must be pure Dart. Move Flutter widgets to lib/ui.',
      );
    });

    test('ui/ does not import crypto/ directly', () {
      final offenders = _scanForCryptoImports('$_libRoot/ui');
      expect(
        offenders,
        isEmpty,
        reason:
            'lib/ui must reach the crypto layer through lib/domain use-cases, '
            'never via a direct import.',
      );
    });

    test('layering check itself catches a synthetic violation', () {
      const sample = "import 'package:flutter/material.dart';";
      expect(_flutterImport.hasMatch(sample), isTrue);
      const ok = "import 'dart:convert';";
      expect(_flutterImport.hasMatch(ok), isFalse);
      const cryptoSample = "import '../crypto/x3dh.dart';";
      expect(_cryptoImport.hasMatch(cryptoSample), isTrue);
    });
  });
}

List<String> _scanForFlutterImports(String dir) => _scan(dir, _flutterImport);

List<String> _scanForCryptoImports(String dir) => _scan(dir, _cryptoImport);

List<String> _scan(String dir, RegExp pattern) {
  final root = Directory(dir);
  if (!root.existsSync()) return [];
  final hits = <String>[];
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final lines = entity.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      if (pattern.hasMatch(lines[i])) {
        hits.add('${entity.path}:${i + 1}: ${lines[i].trim()}');
      }
    }
  }
  return hits;
}
