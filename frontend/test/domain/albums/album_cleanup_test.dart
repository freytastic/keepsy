import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/domain/albums/album_cleanup.dart';

class _Store implements AlbumCleanupStore {
  final records = <String, CleanupRecord>{};

  @override
  Future<Map<String, CleanupRecord>> pending() async => Map.of(records);

  @override
  Future<void> put(String albumId, {required bool confirmed}) async {
    final was = records[albumId];
    records[albumId] = (
      confirmed: (was?.confirmed ?? false) || confirmed,
      version: (was?.version ?? -1) + 1,
    );
  }

  @override
  Future<void> removeIfUnchanged(String albumId, int version) async {
    if (records[albumId]?.version == version) records.remove(albumId);
  }

  Map<String, bool> get flags =>
      {for (final e in records.entries) e.key: e.value.confirmed};
}

class _Harness {
  final store = _Store();
  final presence = <String, AlbumPresence>{};
  Completer<void>? holdProbe;
  final wiped = <String>[];
  int wipeFailures = 0;
  final timers = <Duration>[];
  void Function()? retry;
  late final queue = AlbumCleanupQueue(
    store: store,
    probe: (id) async {
      final hold = holdProbe;
      if (hold != null) await hold.future;
      return presence[id] ?? AlbumPresence.unknown;
    },
    wipe: (id) async {
      if (wipeFailures > 0) {
        wipeFailures--;
        throw StateError('disk');
      }
      wiped.add(id);
    },
    timer: (d, f) {
      timers.add(d);
      retry = f;
      return Timer(const Duration(days: 1), () {});
    },
  );
}

void main() {
  test('a server confirmed album is wiped and forgotten', () async {
    final h = _Harness();
    await h.queue.albumGone('a1');
    await h.queue.drain();
    expect(h.wiped, ['a1']);
    expect(h.store.records, isEmpty);
  });

  test('an album a stale listing left out is kept when still ours', () async {
    final h = _Harness()..presence['a1'] = AlbumPresence.member;
    await h.queue.albumMissing('a1');
    await h.queue.drain();
    expect(h.wiped, isEmpty);
    expect(h.store.records, isEmpty);
  });

  test('a probe that cannot reach the server keeps the record and retries',
      () async {
    final h = _Harness();
    await h.queue.albumMissing('a1');
    await h.queue.drain();
    expect(h.store.flags, {'a1': false});
    expect(h.timers, isNotEmpty);

    h.presence['a1'] = AlbumPresence.gone;
    h.retry!();
    await h.queue.drain();
    expect(h.wiped, ['a1']);
    expect(h.store.records, isEmpty);
  });

  test('a failed wipe stays durable until one finishes', () async {
    final h = _Harness()..wipeFailures = 2;
    // The enqueue and this call coalesce, so both failures land here
    await h.queue.albumGone('a1');
    await h.queue.drain();
    expect(h.wiped, isEmpty);
    expect(h.store.flags, {'a1': true});
    await h.queue.drain();
    expect(h.wiped, ['a1']);
    expect(h.store.records, isEmpty);
  });

  test('a later omission never undoes a server confirmation', () async {
    final h = _Harness()
      ..wipeFailures = 1
      ..presence['a1'] = AlbumPresence.member;
    await h.queue.albumGone('a1');
    await h.queue.drain();
    await h.queue.albumMissing('a1');
    await h.queue.drain();
    expect(h.wiped, ['a1'], reason: 'confirmed records are never probed away');
  });

  test('a shut down queue records nothing new', () async {
    final h = _Harness();
    await h.queue.shutdown();
    await h.queue.albumGone('a1');
    expect(h.store.records, isEmpty);
  });

  test('a removal event during a probe survives the probe saying member',
      () async {
    final h = _Harness()
      ..presence['a1'] = AlbumPresence.member
      ..holdProbe = Completer<void>();
    await h.queue.albumMissing('a1');
    await Future<void>.delayed(Duration.zero);

    await h.queue.albumGone('a1');
    h.holdProbe!.complete();
    h.holdProbe = null;
    await h.queue.drain();
    await h.queue.drain();

    expect(h.wiped, ['a1']);
    expect(h.store.records, isEmpty);
  });

  test('a report that lands during the wipe keeps its record', () async {
    final h = _Harness();
    final gate = Completer<void>();
    final queue = AlbumCleanupQueue(
      store: h.store,
      probe: (_) async => AlbumPresence.gone,
      wipe: (id) async {
        await gate.future;
        h.wiped.add(id);
      },
      timer: (d, f) => Timer(const Duration(days: 1), () {}),
    );
    await queue.albumGone('a1');
    await Future<void>.delayed(Duration.zero);
    await h.store.put('a1', confirmed: true);
    gate.complete();
    await queue.drain();
    expect(h.wiped, ['a1', 'a1'],
        reason: 'the newer report gets its own wipe instead of being dropped');
    expect(h.store.records, isEmpty);
    await queue.shutdown();
  });
}
