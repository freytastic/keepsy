import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:keepsy/diagnostics/trace.dart';

typedef ClientFactory = http.Client Function();

// Keep in sync with MaxBlobBytes in the media service
const int kMaxMediaBytes = 64 * 1024 * 1024;

class S3TransportException implements Exception {
  final String reason;
  final int attempts;

  const S3TransportException(this.reason, this.attempts);

  @override
  String toString() => 'S3TransportException($reason after $attempts attempts)';
}

class S3Transport {
  final ClientFactory _newClient;
  final int maxDownloadAttempts;
  final Duration baseDeadline;
  final int maxMediaBytes;
  final int bytesPerSecondFloor;
  final Duration Function(int attempt) backoff;

  http.Client? _client;

  S3Transport({
    ClientFactory? clientFactory,
    this.maxDownloadAttempts = 3,
    this.baseDeadline = const Duration(seconds: 8),
    // Values above the server limit indicate corrupt metadata
    this.maxMediaBytes = kMaxMediaBytes,
    this.bytesPerSecondFloor = 64 * 1024,
    Duration Function(int)? backoff,
  })  : assert(maxDownloadAttempts > 0),
        assert(bytesPerSecondFloor > 0),
        assert(maxMediaBytes > 0),
        _newClient = clientFactory ?? (() => http.Client()),
        backoff = backoff ?? _defaultBackoff;

  http.Client get _live => _client ??= _newClient();

  void _discardClient() {
    final client = _client;
    _client = null;
    client?.close();
  }

  // Clamp corrupt sizes without reducing the transfer budget for valid media
  Duration deadlineFor(int bytes) {
    final bounded = bytes > maxMediaBytes ? maxMediaBytes : bytes;
    return baseDeadline +
        Duration(milliseconds: (bounded * 1000 / bytesPerSecondFloor).round());
  }

  Future<http.Response> put(
    Uri url,
    Uint8List body,
    Map<String, String> headers, {
    Map<String, Object?> traceFields = const {},
  }) async {
    final uploadDeadline = deadlineFor(body.length);
    final span = Trace.start('media.upload', fields: {
      ...traceFields,
      'bytes': body.length,
      'deadline_ms': uploadDeadline.inMilliseconds,
      'host': Trace.url(url.toString()),
    });
    final abort = Completer<void>();
    final timeout = Completer<http.Response>();
    final request = _AbortableRequest('PUT', url, abort.future, body: body)
      ..headers.addAll(headers);
    final timer = Timer(uploadDeadline, () {
      timeout.completeError(
        const S3TransportException('deadline', 1),
        StackTrace.current,
      );
      if (!abort.isCompleted) abort.complete();
    });

    try {
      Future<http.Response> send() async =>
          http.Response.fromStream(await _live.send(request));
      final response = await Future.any([
        send(),
        timeout.future,
      ]);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        span.end(fields: {'status': response.statusCode});
      } else {
        span.fail('http_${response.statusCode}',
            fields: {'status': response.statusCode});
      }
      return response;
    } catch (error) {
      final reason =
          error is S3TransportException ? error.reason : Trace.reasonOf(error);
      span.fail(reason);
      if (error is S3TransportException) rethrow;
      throw S3TransportException(reason, 1);
    } finally {
      timer.cancel();
    }
  }

  // Re-presign between attempts because the original URL may have expired
  Future<http.Response> get(
    Uri url, {
    int expectedBytes = 0,
    Map<String, Object?> traceFields = const {},
    Future<Uri> Function()? refreshUrl,
  }) async {
    final deadline = deadlineFor(expectedBytes);
    Object? lastError;
    var target = url;

    for (var attempt = 1; attempt <= maxDownloadAttempts; attempt++) {
      if (attempt > 1 && refreshUrl != null) {
        try {
          target = await refreshUrl();
        } catch (_) {
          // The previous URL may still be valid
        }
      }
      final span = Trace.start('media.s3Get', fields: {
        ...traceFields,
        'bytes': expectedBytes,
        'attempt': attempt,
        'deadline_ms': deadline.inMilliseconds,
        'host': Trace.url(target.toString()),
      });
      // Cancel only this request; the client is shared by concurrent downloads
      final abort = Completer<void>();
      final timeout = Completer<http.Response>();
      final request = _AbortableRequest('GET', target, abort.future);
      final timer = Timer(deadline, () {
        timeout.completeError(
          S3TransportException('deadline', attempt),
          StackTrace.current,
        );
        if (!abort.isCompleted) abort.complete();
      });

      try {
        Future<http.Response> send() async =>
            http.Response.fromStream(await _live.send(request));
        final response = await Future.any([send(), timeout.future]);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          span.end(fields: {'status': response.statusCode});
          return response;
        }
        span.fail('http_${response.statusCode}',
            fields: {'status': response.statusCode});
        // Expired signatures arrive as retryable 403 responses
        if (attempt == maxDownloadAttempts ||
            !_isRetryableStatus(response.statusCode)) {
          return response;
        }
        lastError =
            S3TransportException('http_${response.statusCode}', attempt);
        await Future<void>.delayed(backoff(attempt));
        continue;
      } catch (error) {
        lastError = error;
        final reason = error is S3TransportException
            ? error.reason
            : Trace.reasonOf(error);
        span.fail(reason);
        if (attempt == maxDownloadAttempts || !_isRetryable(error)) {
          throw S3TransportException(reason, attempt);
        }
        await Future<void>.delayed(backoff(attempt));
      } finally {
        timer.cancel();
      }
    }

    throw S3TransportException(
      lastError == null ? 'unknown' : Trace.reasonOf(lastError),
      maxDownloadAttempts,
    );
  }

  static bool _isRetryable(Object error) {
    // A deadline is the transport's own abort, not the store's answer
    if (error is S3TransportException) return error.reason == 'deadline';
    return isTransportFailure(error);
  }

  // 403 is retryable bcs object stores use it for expired signatures
  static bool _isRetryableStatus(int status) =>
      status == 403 || status == 408 || status == 429 || status >= 500;

  // Match dart:io errors by name
  static bool isTransportFailure(Object error) {
    final type = error.runtimeType.toString();
    return error is TimeoutException ||
        error is http.ClientException ||
        type == 'SocketException' ||
        type == 'HandshakeException' ||
        type == 'HttpException';
  }

  void close() => _discardClient();
}

// Cancels one request without closing the shared client
class _AbortableRequest extends http.Request with http.Abortable {
  @override
  final Future<void>? abortTrigger;

  _AbortableRequest(super.method, super.url, this.abortTrigger,
      {Uint8List? body}) {
    if (body != null) bodyBytes = body;
  }
}

Duration _defaultBackoff(int attempt) => Duration(milliseconds: 250 * attempt);
