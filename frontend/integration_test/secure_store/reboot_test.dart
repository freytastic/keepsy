import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:keepsy/secure_store/secure_key_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // An actual app restart is simulated by spinning a fresh store instance , wrapper
  // key + envelope blob live in OS managed storage, so a new Dart instance
  // sees prior state. A real SIGKILL test would run two separate flutter
  // processes : deferred until manual round trip surfaces a state loss bug
  test('survives store-instance reboot', () async {
    final s1 = createSecureKeyStore();
    await s1.initialize();
    final pt = Uint8List.fromList(List.generate(32, (i) => i ^ 0x5A));
    final h = await s1.put('reboot.key', pt);

    final s2 = createSecureKeyStore();
    await s2.initialize();
    final got = await s2.use(h, (b) async => Uint8List.fromList(b));
    expect(got, equals(pt));

    await s2.wipeAll();
  });
}
