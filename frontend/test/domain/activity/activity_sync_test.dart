import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/domain/activity/activity_sync.dart';

AlbumModel _album(String id) => AlbumModel(
      id: id,
      nameCt: null,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  late List<List<String>> observed;
  late int settled;
  late List<AlbumModel> shelf;

  ActivitySync sync({
    Future<void> Function(List<AlbumModel>)? observe,
    Duration quiet = const Duration(milliseconds: 20),
  }) =>
      ActivitySync(
        observe: observe ??
            (albums) async => observed.add([for (final a in albums) a.id]),
        afterEach: () async => settled++,
        current: () => shelf,
        quiet: quiet,
      );

  setUp(() {
    observed = [];
    settled = 0;
    shelf = [_album('a')];
  });

  // The launch listing used to be the only moment anything was compared, so
  // an owner who kept the app open never heard about a member's photos
  test('every server listing is compared, not just the first', () async {
    final s = sync();
    await s.listed();
    shelf = [_album('a'), _album('b')];
    await s.listed();

    expect(observed, [
      ['a'],
      ['a', 'b'],
    ]);
    expect(settled, 2);
  });

  // Incomplete local restores are not evidence of departures
  test('nothing is compared before the server has answered once', () async {
    final s = sync();
    s.nudge();
    await s.flush();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(observed, isEmpty);
  });

  test('a nudge compares the shelf once things go quiet', () async {
    final s = sync();
    await s.listed();
    observed.clear();

    s.nudge();
    s.nudge();
    s.nudge();
    expect(observed, isEmpty, reason: 'a burst of photos is one look');
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(observed, hasLength(1));
  });

  test('flush compares right away and cancels the pending nudge', () async {
    final s = sync(quiet: const Duration(milliseconds: 30));
    await s.listed();
    observed.clear();

    s.nudge();
    await s.flush();
    expect(observed, hasLength(1));
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(observed, hasLength(1));
  });

  // Two comparisons racing would each read the same old snapshot and the
  // slower one would write its stale view last
  test('overlapping requests run one at a time, latest shelf last', () async {
    final gate = Completer<void>();
    var running = 0;
    var maxRunning = 0;
    final s = sync(observe: (albums) async {
      running++;
      maxRunning = running > maxRunning ? running : maxRunning;
      observed.add([for (final a in albums) a.id]);
      if (observed.length == 1) await gate.future;
      running--;
    });

    final first = s.listed();
    await Future<void>.delayed(Duration.zero);
    shelf = [_album('b')];
    final second = s.listed();
    shelf = [_album('c')];
    final third = s.listed();
    gate.complete();
    await Future.wait([first, second, third]);

    expect(maxRunning, 1);
    expect(observed, [
      ['a'],
      ['c'],
    ]);
  });

  test('a failing comparison is swallowed and the next one still runs',
      () async {
    var calls = 0;
    final s = sync(observe: (albums) async {
      calls++;
      if (calls == 1) throw StateError('disk');
    });

    await s.listed();
    await s.listed();

    expect(calls, 2);
  });

  // The terminal wipe clears the store: nothing may write a snapshot after it
  test('a stopped sync never compares again', () async {
    final s = sync();
    await s.listed();
    observed.clear();

    s.nudge();
    s.stop();
    await s.listed();
    await s.flush();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(observed, isEmpty);
  });

  // A wipe can land while a comparison is still running: the follow up it
  // had queued must not write a snapshot after the store was cleared
  test('stopping mid run drops the queued follow up', () async {
    final gate = Completer<void>();
    final s = sync(observe: (albums) async {
      observed.add([for (final a in albums) a.id]);
      if (observed.length == 1) await gate.future;
    });

    final first = s.listed();
    await Future<void>.delayed(Duration.zero);
    final second = s.listed();
    s.stop();
    gate.complete();
    await Future.wait([first, second]);

    expect(observed, hasLength(1));
  });

  // The wipe clears the store right after stopping: a comparison still inside
  // observe would otherwise write its snapshot into the cleared store
  test('stopping waits for the comparison already running', () async {
    final gate = Completer<void>();
    var finished = false;
    final s = sync(observe: (albums) async {
      await gate.future;
      finished = true;
    });

    unawaited(s.listed());
    await Future<void>.delayed(Duration.zero);
    var stopped = false;
    final stopping = s.stop().then((_) => stopped = true);
    await Future<void>.delayed(Duration.zero);
    expect(stopped, isFalse);

    gate.complete();
    await stopping;
    expect(finished, isTrue);
  });

  // A key-change alarm is written outside a comparison. Opening Activity and
  // the wipe must both wait for it
  group('alarms', () {
    test('flush waits for an alarm still being written', () async {
      final gate = Completer<void>();
      var written = false;
      final s = sync();
      await s.listed();

      unawaited(s.alarm(() async {
        await gate.future;
        written = true;
      }));
      var flushed = false;
      final flushing = s.flush().then((_) => flushed = true);
      await Future<void>.delayed(Duration.zero);
      expect(flushed, isFalse);

      gate.complete();
      await flushing;
      expect(written, isTrue);
    });

    test('an alarm is not dropped before the first listing', () async {
      var written = false;
      await sync().alarm(() async => written = true);
      expect(written, isTrue);
    });

    test('stop waits for alarms, and none are written after it', () async {
      final gate = Completer<void>();
      var writes = 0;
      final s = sync();
      unawaited(s.alarm(() async {
        await gate.future;
        writes++;
      }));
      final stopping = s.stop();
      gate.complete();
      await stopping;
      await s.alarm(() async => writes++);

      expect(writes, 1);
    });
  });
}
