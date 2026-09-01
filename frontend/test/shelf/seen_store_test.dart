import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/shelf/seen_store_impl.dart';

Uint8List _key([int fill = 0x11]) =>
    Uint8List.fromList(List<int>.filled(32, fill));

void main() {
  late Directory tmp;
  late File file;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('seen_');
    file = File('${tmp.path}/keepsy_seen.kec');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<SealedSeenStore> open([int fill = 0x11]) =>
      SealedSeenStore.open(file: file, cacheRootKey: _key(fill));

  test('markSeen survives a restart', () async {
    final store = await open();
    await store.markSeen('a', 7);
    await store.flush();

    final reopened = await open();
    expect(reopened.lastSeen('a'), 7);
  });

  test('the watermark is monotonic', () async {
    final store = await open();
    await store.markSeen('a', 9);
    await store.markSeen('a', 4);
    expect(store.lastSeen('a'), 9,
        reason: 'a stale event must not un-see an album');
  });

  test('notifies listeners only when the watermark moves', () async {
    final store = await open();
    var notifications = 0;
    store.addListener(() => notifications++);

    await store.markSeen('a', 5);
    await store.markSeen('a', 5);
    await store.markSeen('a', 2);
    expect(notifications, 1);
  });

  test('the file on disk is sealed, not plaintext json', () async {
    final store = await open();
    await store.markSeen('album-one', 42);
    await store.flush();

    final raw = await file.readAsBytes();
    expect(String.fromCharCodes(raw).contains('album-one'), isFalse);
    expect(String.fromCharCodes(raw).contains('42'), isFalse);
  });

  test('a different cache key reads as empty rather than throwing', () async {
    final store = await open();
    await store.markSeen('a', 7);
    await store.flush();

    final other = await open(0x22);
    expect(other.lastSeen('a'), 0);
  });

  test('a corrupt file reads as empty', () async {
    await file.writeAsBytes(Uint8List.fromList([1, 2, 3, 4, 5]));
    final store = await open();
    expect(store.lastSeen('a'), 0);
  });

  test('forget drops one album', () async {
    final store = await open();
    await store.markSeen('a', 3);
    await store.markSeen('b', 4);
    store.forget('a');
    await store.flush();

    final reopened = await open();
    expect(reopened.lastSeen('a'), 0);
    expect(reopened.lastSeen('b'), 4);
  });

  test('an album seen while empty is still known after a restart', () async {
    final a = await open();
    await a.markSeen('empty-album', 0);
    await a.flush();

    final b = await open();
    expect(b.knows('empty-album'), isTrue,
        reason: 'unknown on reopen means startup reseeds it at whatever '
            'generation it has reached, marking new frames read');
    expect(b.lastSeen('empty-album'), 0);
  });
}
