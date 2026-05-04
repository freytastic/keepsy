import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:keepsy/secure_store/key_store_exceptions.dart';
import 'package:keepsy/secure_store/secure_key_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('wipeAll undecrypts prior handles : fresh put still works', () async {
    final s = createSecureKeyStore();
    await s.initialize();
    final a = await s.put('a', Uint8List.fromList([1, 2, 3, 4]));
    final b = await s.put('b', Uint8List.fromList([5, 6, 7, 8]));

    await s.wipeAll();
    await s.initialize();

    await expectLater(
        s.use(a, (_) async => 0), throwsA(isA<KeyNotFoundException>()));
    await expectLater(
        s.use(b, (_) async => 0), throwsA(isA<KeyNotFoundException>()));

    final c = await s.put('c', Uint8List.fromList([9, 10]));
    final got = await s.use(c, (x) async => Uint8List.fromList(x));
    expect(got, equals(Uint8List.fromList([9, 10])));

    await s.wipeAll();
  });
}
