import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:keepsy/data/api/s3_transport.dart';

class _RecordingClient extends http.BaseClient {
  final http.Client inner;
  bool closed = false;

  _RecordingClient(this.inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      inner.send(request);

  @override
  void close() {
    closed = true;
    inner.close();
  }
}

void main() {
  final url = Uri.parse('http://s3.local/object?X-Amz-Signature=SECRET');
  final body = Uint8List.fromList(List.generate(64, (i) => i));

  test('PUT preserves the buffered body and required headers', () async {
    late http.BaseRequest captured;
    late List<int> capturedBody;
    final client =
        _RecordingClient(MockClient.streaming((request, stream) async {
      captured = request;
      capturedBody = await stream.toBytes();
      return http.StreamedResponse(Stream.empty(), 200);
    }));
    final transport = S3Transport(clientFactory: () => client);

    final response = await transport.put(
      url,
      body,
      {'content-type': 'application/octet-stream', 'x-checksum': 'abc'},
    );

    expect(response.statusCode, 200);
    expect(captured.method, 'PUT');
    expect(captured.contentLength, body.length);
    expect(captured.headers['x-checksum'], 'abc');
    expect(capturedBody, body);
  });

  test('PUT deadline aborts its own request without closing the client',
      () async {
    final client = _RecordingClient(MockClient.streaming(
      (_, __) => Completer<http.StreamedResponse>().future,
    ));
    final transport = S3Transport(
      clientFactory: () => client,
      baseDeadline: const Duration(milliseconds: 20),
    );

    await expectLater(
      transport.put(url, body, {}),
      throwsA(isA<S3TransportException>()
          .having((e) => e.reason, 'reason', 'deadline')
          .having((e) => e.toString(), 'message', isNot(contains('SECRET')))),
    );
    expect(client.closed, isFalse);
  });

  test('deadline scales through the server ceiling and bounds corrupt sizes',
      () {
    final transport = S3Transport(
      baseDeadline: const Duration(seconds: 10),
      maxMediaBytes: 20 * 1024,
      bytesPerSecondFloor: 1024,
    );

    expect(transport.deadlineFor(0), const Duration(seconds: 10));
    expect(transport.deadlineFor(5 * 1024), const Duration(seconds: 15));
    expect(transport.deadlineFor(20 * 1024), const Duration(seconds: 30));
    expect(
        transport.deadlineFor(100 * 1024 * 1024), const Duration(seconds: 30));
    expect(S3Transport().deadlineFor(kMaxMediaBytes),
        const Duration(seconds: 1032));
  });

  test('an expired signature 403 is re-presigned and retried', () async {
    final served = <String?>[];
    final client = MockClient.streaming((request, _) async {
      final sig = request.url.queryParameters['sig'];
      served.add(sig);
      if (sig == 'fresh') {
        return http.StreamedResponse(Stream.value(utf8.encode('ok')), 200);
      }
      return http.StreamedResponse(
          Stream.value(utf8.encode('<Error>AccessDenied</Error>')), 403);
    });
    final transport = S3Transport(
      clientFactory: () => client,
      backoff: (_) => Duration.zero,
    );

    final response = await transport.get(
      Uri.parse('https://s3.invalid/o?sig=expired'),
      refreshUrl: () async => Uri.parse('https://s3.invalid/o?sig=fresh'),
    );

    expect(response.statusCode, 200);
    expect(served, ['expired', 'fresh']);
  });

  test('a 404 is returned without burning retries', () async {
    var served = 0;
    final client = MockClient.streaming((_, __) async {
      served++;
      return http.StreamedResponse(const Stream.empty(), 404);
    });
    final transport = S3Transport(clientFactory: () => client);

    final response = await transport.get(Uri.parse('https://s3.invalid/gone'));

    expect(response.statusCode, 404);
    expect(served, 1);
  });

  test('a download retry asks for a fresh presigned url', () async {
    var served = 0;
    final client = MockClient.streaming((request, _) async {
      served++;
      if (request.url.queryParameters['sig'] == 'fresh') {
        return http.StreamedResponse(Stream.value(utf8.encode('ok')), 200);
      }
      throw http.ClientException('connection reset by peer');
    });
    final transport = S3Transport(clientFactory: () => client);

    final response = await transport.get(
      Uri.parse('https://s3.invalid/o?sig=stale'),
      refreshUrl: () async => Uri.parse('https://s3.invalid/o?sig=fresh'),
    );

    expect(response.statusCode, 200);
    expect(served, 2);
  });

  test('a download deadline aborts without closing the shared client',
      () async {
    final client = _RecordingClient(MockClient.streaming(
      (_, __) => Completer<http.StreamedResponse>().future,
    ));
    final transport = S3Transport(
      clientFactory: () => client,
      maxDownloadAttempts: 1,
      baseDeadline: const Duration(milliseconds: 20),
    );

    await expectLater(
      transport.get(url),
      throwsA(isA<S3TransportException>()
          .having((e) => e.reason, 'reason', 'deadline')),
    );
    expect(client.closed, isFalse);
  });
}
