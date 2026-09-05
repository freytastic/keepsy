import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:keepsy/data/api/api_client.dart';
import 'package:keepsy/data/api/api_error.dart';
import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/data/api/s3_transport.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';

class _FakeApiClient extends ApiClient {
  final List<String> posts = [];
  final List<String> deletes = [];
  bool failReservation = false;
  bool failConfirm = false;
  int flakyConfirms = 0;
  final List<int> confirmStatuses = [];

  @override
  Future<http.Response> post(String path, {Map<String, dynamic>? body}) async {
    posts.add(path);
    if (path.endsWith('/upload-url')) {
      if (failReservation) throw StateError('reservation failed');
      return http.Response(
        jsonEncode({
          'media_id': _mediaId,
          'upload_url': 'https://s3.invalid/file?signed=secret',
          'required_header': {'x-checksum': 'abc'},
        }),
        201,
      );
    }
    if (path.endsWith('/confirm')) {
      if (confirmStatuses.isNotEmpty) {
        final status = confirmStatuses.removeAt(0);
        throw ApiError(code: 'E_TEST', message: 'x', httpStatus: status);
      }
      if (flakyConfirms > 0) {
        flakyConfirms--;
        throw http.ClientException('connection reset by peer');
      }
      if (failConfirm) throw StateError('confirm failed');
      return http.Response(jsonEncode({'media_generation': 7}), 200);
    }
    throw StateError('unexpected POST $path');
  }

  @override
  Future<http.Response> delete(String path) async {
    deletes.add(path);
    return http.Response('', 204);
  }
}

const _mediaId = '00010203-0405-0607-0809-0a0b0c0d0e0f';

UploadEnvelope _envelope() => UploadEnvelope(
      mediaId: Uint8List.fromList(List.generate(16, (i) => i)),
      cipherBytes: Uint8List.fromList([1, 2, 3, 4]),
      wrapNonce: Uint8List(12),
      wrapTagCT: Uint8List(48),
      epoch: 0,
      blobSize: 4,
      blobSha256: Uint8List(32),
      mediaType: 'photo',
      mimeType: 'image/jpeg',
      filePlaintext: Uint8List.fromList([9]),
    );

S3Transport _transport(int status) => S3Transport(
      clientFactory: () => MockClient.streaming((_, body) async {
        await body.drain<void>();
        return http.StreamedResponse(const Stream.empty(), status);
      }),
      maxDownloadAttempts: 1,
    );

void main() {
  const albumId = '11111111-1111-1111-1111-111111111111';
  final abortPath = '/albums/$albumId/media/$_mediaId/pending';

  test('a failed object PUT aborts the server reservation', () async {
    final api = _FakeApiClient();
    final media = MediaApi(api, transport: _transport(503));

    await expectLater(
      media.upload(albumId: albumId, envelope: _envelope()),
      throwsException,
    );

    expect(api.deletes, [abortPath]);
    expect(api.posts.where((p) => p.endsWith('/confirm')), isEmpty);
  });

  test('a terminal confirmation failure is not retried or aborted', () async {
    final api = _FakeApiClient()..failConfirm = true;
    final media = MediaApi(api, transport: _transport(200));

    await expectLater(
      media.upload(albumId: albumId, envelope: _envelope()),
      throwsA(isA<StateError>()),
    );

    expect(api.deletes, isEmpty);
    expect(api.posts.where((p) => p.endsWith('/confirm')).length, 1);
  });

  test('a flaky confirmation is retried rather than thrown away', () async {
    final api = _FakeApiClient()..flakyConfirms = 2;
    final media = MediaApi(api, transport: _transport(200));

    final result = await media.upload(albumId: albumId, envelope: _envelope());

    expect(result.mediaGeneration, 7);
    expect(api.posts.where((p) => p.endsWith('/confirm')).length, 3);
    expect(api.deletes, isEmpty);
  });

  test('a 503 confirmation is retried, a 400 is not', () async {
    final transient = _FakeApiClient()..confirmStatuses.addAll([503, 429]);
    final media = MediaApi(transient, transport: _transport(200));
    final result = await media.upload(albumId: albumId, envelope: _envelope());
    expect(result.mediaGeneration, 7);
    expect(transient.posts.where((p) => p.endsWith('/confirm')).length, 3);

    final terminal = _FakeApiClient()..confirmStatuses.addAll([400, 400, 400]);
    final media2 = MediaApi(terminal, transport: _transport(200));
    await expectLater(
      media2.upload(albumId: albumId, envelope: _envelope()),
      throwsA(isA<ApiError>()),
    );
    expect(terminal.posts.where((p) => p.endsWith('/confirm')).length, 1);
  });

  test('reservation failure creates nothing to abort', () async {
    final api = _FakeApiClient()..failReservation = true;
    final media = MediaApi(api, transport: _transport(200));

    await expectLater(
      media.upload(albumId: albumId, envelope: _envelope()),
      throwsA(isA<StateError>()),
    );

    expect(api.deletes, isEmpty);
  });

  test('successful upload confirms and does not abort', () async {
    final api = _FakeApiClient();
    final media = MediaApi(api, transport: _transport(200));

    final result = await media.upload(albumId: albumId, envelope: _envelope());

    expect(result.mediaGeneration, 7);
    expect(api.deletes, isEmpty);
  });
}
