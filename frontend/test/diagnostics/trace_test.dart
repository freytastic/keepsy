import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/diagnostics/trace.dart';

List<String> capture(void Function() body) {
  final lines = <String>[];
  runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, __, ___, line) => lines.add(line),
    ),
  );
  return lines;
}

Future<List<String>> captureAsync(Future<void> Function() body) async {
  final lines = <String>[];
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, __, ___, line) => lines.add(line),
    ),
  );
  return lines;
}

void main() {
  setUp(() => Trace.debugEnabled = true);
  tearDown(() => Trace.debugEnabled = null);

  test('is disabled by default under flutter test', () {
    Trace.debugEnabled = null;
    expect(Trace.enabled, isFalse);
    expect(capture(() => Trace.event('hidden')), isEmpty);
  });

  test('events are parseable and scrub field whitespace', () {
    final lines = capture(() {
      Trace.event('album.open', fields: {'album': 'two words\nand more'});
    });

    expect(lines, hasLength(1));
    expect(lines.single, startsWith('$kTracePrefix|'));
    expect(lines.single.split('\n'), hasLength(1));
    expect(lines.single, contains('album=two_words_and_more'));
  });

  test('spans emit one terminal duration', () async {
    final lines = await captureAsync(() async {
      final span = Trace.start('media.fetch', traceId: 'deadbeef');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      span.end(fields: {'tier': 'l2'});
      span.fail('late');
    });

    expect(lines, hasLength(2));
    expect(lines.first, contains('media.fetch.start'));
    expect(lines.last, contains('media.fetch.end'));
    expect(lines.last, contains('|dur='));
    expect(lines.last, contains('tid=deadbeef'));
  });

  test('nested spans inherit the ambient trace id', () async {
    final lines = await captureAsync(() async {
      await Trace.withId('feedface', () async {
        Trace.event('cache.hit');
        Trace.start('cache.read').end();
      });
    });

    expect(lines, everyElement(contains('tid=feedface')));
  });

  test('URL helper removes signatures and tickets', () {
    final safe = Trace.url(
      'https://s3.example.com/object?X-Amz-Signature=SECRET',
    );
    expect(safe, 'https://s3.example.com/object');
    expect(safe, isNot(contains('SECRET')));
  });

  test('failure reasons never echo exception messages', () {
    final error = const SocketException(
      'failed https://s3.local/object?X-Amz-Signature=SECRET',
    );
    expect(Trace.reasonOf(error), 'SocketException');
    expect(Trace.reasonOf(error), isNot(contains('SECRET')));
    expect(
      Trace.reasonOf(const SocketException('Connection reset by peer')),
      'SocketException_peerreset',
    );
  });

  test('trace ids satisfy the server request id rule', () {
    expect(Trace.newTraceId(), matches(RegExp(r'^[0-9a-f]{32}$')));
  });
}
