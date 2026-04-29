// Round trip tests for the apierr envelope. The Go side's
// `internal/apierr/apierr_test.go` produces the wire shape, this file is
// the matching consumer. If either side breaks, the other test fails

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:keepsy/services/api_error.dart';
import 'package:keepsy/services/error_mapper.dart';

http.Response _resp(int status, String body) => http.Response(body, status,
    headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  group('ApiError.tryParse', () {
    test('parses a well-formed envelope', () {
      final r = _resp(400,
          '{"code":"E_VALIDATION","message":"invalid email","detail":{"field":"email"}}');
      final err = ApiError.tryParse(r)!;
      expect(err.code, 'E_VALIDATION');
      expect(err.message, 'invalid email');
      expect(err.httpStatus, 400);
      expect(err.detail['field'], 'email');
      expect(err.isValidation, isTrue);
      expect(err.isAuth, isFalse);
    });

    test('handles missing detail field', () {
      final r =
          _resp(401, '{"code":"E_AUTH","message":"missing bearer token"}');
      final err = ApiError.tryParse(r)!;
      expect(err.code, 'E_AUTH');
      expect(err.detail, isEmpty);
      expect(err.isAuth, isTrue);
    });

    test('returns null for 2xx responses', () {
      expect(ApiError.tryParse(_resp(200, '{"ok":true}')), isNull);
      expect(ApiError.tryParse(_resp(204, '')), isNull);
    });

    test('returns null when body is not the envelope shape', () {
      // Plain text from a misconfigured proxy
      expect(ApiError.tryParse(_resp(502, 'Bad Gateway')), isNull);
      // JSON but missing required fields
      expect(ApiError.tryParse(_resp(500, '{"error":"oops"}')), isNull);
      // Empty body
      expect(ApiError.tryParse(_resp(500, '')), isNull);
    });

    test('fromResponse falls back to E_UNKNOWN for non-envelope bodies', () {
      final err = ApiError.fromResponse(_resp(502, 'Bad Gateway'));
      expect(err.code, 'E_UNKNOWN');
      expect(err.httpStatus, 502);
      expect(err.detail['raw_body'], 'Bad Gateway');
    });
  });

  group('mapApiError', () {
    test('E_AUTH triggers reauth recovery', () {
      final ux = mapApiError(
          ApiError(code: 'E_AUTH', message: 'expired', httpStatus: 401));
      expect(ux.action, ErrorRecovery.abortAndReauth);
      expect(ux.isTransient, isFalse);
    });

    test('E_RATE_LIMITED is transient + retry', () {
      final ux = mapApiError(
          ApiError(code: 'E_RATE_LIMITED', message: '', httpStatus: 429));
      expect(ux.action, ErrorRecovery.retry);
      expect(ux.isTransient, isTrue);
    });

    test('E_SIG_INVALID surfaces TOFU action', () {
      final ux = mapApiError(ApiError(
          code: 'E_SIG_INVALID', message: 'sig fail', httpStatus: 400));
      expect(ux.action, ErrorRecovery.abortAndShowTofu);
      expect(ux.isTransient, isFalse);
    });

    test('E_VALIDATION uses the server message verbatim', () {
      final ux = mapApiError(ApiError(
          code: 'E_VALIDATION', message: 'email is required', httpStatus: 400));
      expect(ux.userMessage, 'email is required');
    });

    test('unknown codes fall through with a generic message', () {
      final ux = mapApiError(
          ApiError(code: 'E_BRAND_NEW_THING', message: '', httpStatus: 418));
      expect(ux.userMessage, contains('E_BRAND_NEW_THING'));
      expect(ux.action, ErrorRecovery.none);
    });
  });

  // Roundtrip : every code defined in internal/apierr/apierr.go has a
  // matching mapper case. If the server adds a code, this test reminds the
  // mapper to handle it. (Default case fallback means we don't fail hard,
  // but the user facing msg becomes generic, which we want to know)
  group('parity with server codes', () {
    test('every documented server code has a non-default mapper case', () {
      const documented = [
        'E_VALIDATION',
        'E_AUTH',
        'E_FORBIDDEN',
        'E_NOT_MEMBER',
        'E_MEMBER_REVOKED',
        'E_NOT_FOUND',
        'E_CONFLICT',
        'E_ALBUM_FULL',
        'E_OPK_EXHAUSTED',
        'E_EPOCH_REPLAY',
        'E_INVITE_EXPIRED',
        'E_INVITE_CONSUMED',
        'E_SIG_INVALID',
        'E_MANIFEST_TAMPER',
        'E_RATE_LIMITED',
        'E_INTERNAL',
        'E_NOT_IMPLEMENTED',
      ];
      for (final code in documented) {
        final ux = mapApiError(
            ApiError(code: code, message: 'srv-msg', httpStatus: 400));
        expect(ux.userMessage.contains(code), isFalse,
            reason: '$code is hitting the default fallback — add a case');
      }
    });
  });
}
