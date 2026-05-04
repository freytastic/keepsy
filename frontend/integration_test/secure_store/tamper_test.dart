import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:keepsy/secure_store/key_store_exceptions.dart';
import 'package:keepsy/secure_store/secure_key_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // iOS Keychain items are sandboxed away from the test process : symmetric
  // coverage on iOS would need a debug-only 'tamperEnvelope' method on
  // SecureEnclaveBridge gated by '#if DEBUG'. Deferred, Android flip already
  // exercises the AEAD mismatch → KeyTamperException path
  test('flipped byte in envelope causes KeyTamperException (Android-only)',
      () async {
    if (!Platform.isAndroid) return;
    final store = createSecureKeyStore();
    await store.initialize();
    final h =
        await store.put('tamper.k', Uint8List.fromList(List.filled(32, 0xCC)));

    // path_provider's getApplicationSupportDirectory ≈ ctx.filesDir on Android,
    // which is where KeystoreBridge writes keepsy_secure_store.bin
    final docs = await getApplicationSupportDirectory();
    final f = File('${docs.path}/keepsy_secure_store.bin');
    expect(f.existsSync(), isTrue);
    final raw = f.readAsBytesSync();
    raw[raw.length - 1] ^= 0x01;
    f.writeAsBytesSync(raw);

    await expectLater(
        store.use(h, (_) async => 0), throwsA(isA<KeyTamperException>()));
    await store.wipeAll();
  });
}
