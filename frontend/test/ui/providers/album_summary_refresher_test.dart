import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/ui/providers/album_summary_refresher.dart';

AlbumModel _album(int generation) => AlbumModel(
      id: 'album-1',
      nameCt: null,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      mediaGeneration: generation,
    );

void main() {
  test('a later failure does not discard an already applied result', () async {
    final gates = <Completer<List<AlbumModel>?>>[];
    final applied = <int>[];
    final refresher = AlbumSummaryRefresher(
      fetch: () {
        final c = Completer<List<AlbumModel>?>();
        gates.add(c);
        return c.future;
      },
      apply: (albums) => applied.add(albums.single.mediaGeneration),
    );

    final pending = refresher.refresh();
    refresher.refresh();
    expect(gates, hasLength(1), reason: 'the second ask coalesces');

    gates[0].complete([_album(4)]);
    await pumpEventQueue();
    expect(gates, hasLength(2), reason: 'the coalesced ask still runs');

    gates[1].completeError(StateError('offline'));
    await pending;

    expect(applied, [4],
        reason: 'a failed follow-up must not erase what already landed');
  });

  test('overlapping asks collapse into one follow-up', () async {
    var calls = 0;
    final gates = <Completer<List<AlbumModel>?>>[];
    final refresher = AlbumSummaryRefresher(
      fetch: () {
        calls++;
        final c = Completer<List<AlbumModel>?>();
        gates.add(c);
        return c.future;
      },
      apply: (_) {},
    );

    final pending = refresher.refresh();
    refresher.refresh();
    refresher.refresh();
    expect(calls, 1);

    gates[0].complete(const []);
    await pumpEventQueue();
    expect(calls, 2, reason: 'three asks during one flight is a single redo');

    gates[1].complete(const []);
    await pending;
    expect(calls, 2);
  });

  test('the last fetched summaries are the ones applied', () async {
    var n = 0;
    final applied = <int>[];
    final refresher = AlbumSummaryRefresher(
      fetch: () async => [_album(++n)],
      apply: (albums) => applied.add(albums.single.mediaGeneration),
    );

    final pending = refresher.refresh();
    refresher.refresh();
    await pending;

    expect(applied, [1, 2]);
  });

  test('a null response leaves the summaries alone', () async {
    final applied = <int>[];
    final refresher = AlbumSummaryRefresher(
      fetch: () async => null,
      apply: (albums) => applied.add(albums.length),
    );

    await refresher.refresh();

    expect(applied, isEmpty);
  });

  test('a failed refresh does not escape', () async {
    final refresher = AlbumSummaryRefresher(
      fetch: () async => throw StateError('offline'),
      apply: (_) => fail('must not apply'),
    );

    await refresher.refresh();
  });

  test('sequential refreshes each apply', () async {
    final applied = <int>[];
    var n = 0;
    final refresher = AlbumSummaryRefresher(
      fetch: () async => [_album(++n)],
      apply: (albums) => applied.add(albums.single.mediaGeneration),
    );

    await refresher.refresh();
    await refresher.refresh();

    expect(applied, [1, 2]);
  });
}
