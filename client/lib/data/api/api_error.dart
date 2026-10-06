import 'dart:convert';
import 'package:http/http.dart' as http;

// Typed error envelope ... it matches the wire shape produced by
// `internal/apierr/writer.go` exactly and if either side changes the JSON shape,
// the other must change as well
//   {"code": "E_VALIDATION", "message": "...", "detail": {...}}

class ApiError implements Exception {
  final String code;

  // Human readable message from the server should not  shown to users directly
  // the UI maps `code` to a localized string via `error_mapper.dart`
  final String message;

  final int httpStatus;

  final Map<String, dynamic> detail;

  const ApiError({
    required this.code,
    required this.message,
    required this.httpStatus,
    this.detail = const {},
  });

  factory ApiError.unknown(int httpStatus, String rawBody) => ApiError(
        code: 'E_UNKNOWN',
        message: 'Server returned $httpStatus',
        httpStatus: httpStatus,
        detail: {'raw_body': rawBody},
      );

  static ApiError? tryParse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return null;
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;
      final code = decoded['code'];
      final message = decoded['message'];
      if (code is! String || message is! String) return null;
      final detail = decoded['detail'];
      return ApiError(
        code: code,
        message: message,
        httpStatus: response.statusCode,
        detail: detail is Map<String, dynamic> ? detail : const {},
      );
    } catch (_) {
      return null;
    }
  }

  static ApiError fromResponse(http.Response response) {
    final parsed = tryParse(response);
    if (parsed != null) return parsed;
    return ApiError.unknown(response.statusCode, response.body);
  }

  bool get isAuth => code == 'E_AUTH';
  bool get isRateLimited => code == 'E_RATE_LIMITED';
  bool get isValidation => code == 'E_VALIDATION';
  bool get isInternal => code == 'E_INTERNAL';

  @override
  String toString() => 'ApiError($code, http=$httpStatus, message="$message"'
      '${detail.isEmpty ? '' : ', detail=$detail'})';
}
