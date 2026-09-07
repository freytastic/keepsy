import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:keepsy/data/api/s3_transport.dart';

Uint8List _bytes(int n) => Uint8List.fromList(List.generate(n, (i) => i % 251));

// Drains the request body the way a socket would and records what it saw
class _RecordingClient extends http.BaseClient {
  final List<int> lengths = [];
  final List<int> bodySizes = [];
  final List<Map<String, String>> headers = [];
  int status = 200;
  Object? throwAfterDrain;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lengths.add(request.contentLength ?? -1);
    headers.add(Map.of(request.headers));
    final body = await request.finalize().toBytes();
    bodySizes.add(body.length);
    final err = throwAfterDrain;
    if (err != null) {
      throwAfterDrain = null;
      throw err;
    }
    return http.StreamedResponse(const Stream.empty(), status);
  }
}

void main() {
  late _RecordingClient client;
  late S3Transport transport;

  setUp(() {
    client = _RecordingClient();
    transport = S3Transport(
      clientFactory: () => client,
      uploadChunkBytes: 1024,
    );
  });

  test('reports monotonic progress that ends exactly at the payload size',
      () async {
    final seen = <int>[];
    await transport.put(Uri.parse('https://store/o'), _bytes(4096), const {},
        onBytes: seen.add);

    expect(seen, isNotEmpty);
    expect(seen.last, 4096, reason: 'progress must finish at the byte count');
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i], greaterThan(seen[i - 1]));
    }
    expect(seen.every((v) => v <= 4096), isTrue,
        reason: 'progress must never exceed the payload');
  });

  test('sets contentLength explicitly because the presign signs it', () async {
    await transport.put(Uri.parse('https://store/o'), _bytes(2048), const {});
    expect(client.lengths.single, 2048);
    expect(client.bodySizes.single, 2048);
  });

  test('carries the presign required headers through', () async {
    await transport.put(Uri.parse('https://store/o'), _bytes(16), const {
      'Content-Type': 'image/jpeg',
      'x-amz-checksum-sha256': 'abc=',
    });
    expect(client.headers.single['x-amz-checksum-sha256'], 'abc=');
    expect(client.headers.single['Content-Type'], 'image/jpeg');
  });

  test('each attempt builds a fresh request, since a stream cannot be replayed',
      () async {
    client.throwAfterDrain = http.ClientException('reset');
    await expectLater(
      transport.put(Uri.parse('https://store/o'), _bytes(64), const {}),
      throwsA(isA<S3TransportException>()),
    );
    final resp =
        await transport.put(Uri.parse('https://store/o'), _bytes(64), const {});
    expect(resp.statusCode, 200);
    expect(client.bodySizes, [64, 64]);
  });
}
