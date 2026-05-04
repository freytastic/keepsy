import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:keepsy/secure_store/secure_key_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Best effort : heap snapshot inspection requires the vm_service package and
  // a custom test harness, deliberately not adopted here. The host contract
  // test already proves use<T>'s zeroing logic on the buffer reference : this
  // integration variant exists to confirm the same code path runs without
  // crashing against the real platform backed store
  test('use<T> zeroing path runs cleanly on the real impl', () async {
    final s = createSecureKeyStore();
    await s.initialize();
    final sentinel = Uint8List.fromList(List.filled(32, 0xDE));
    final h = await s.put('zero.k', sentinel);

    Uint8List? captured;
    await s.use<void>(h, (b) async {
      // Touch the bytes so theyre materialized
      var sum = 0;
      for (final x in b) {
        sum += x;
      }
      expect(sum, 32 * 0xDE);
      captured = b;
    });

    expect(captured, isNotNull);
    expect(captured!.every((x) => x == 0), isTrue,
        reason: 'store-handed buffer must be zeroed after use<T>');
    // Caller owned copy must be untouched (we passed Uint8List.fromList)
    expect(sentinel.every((x) => x == 0xDE), isTrue);

    await s.wipeAll();
  });
}
