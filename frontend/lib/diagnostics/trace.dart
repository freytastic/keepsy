import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';

const String kTracePrefix = 'keepsy.trace';
const bool _kTraceOverride = bool.fromEnvironment('KEEPSY_TRACE');
const bool _kTraceDefined = bool.hasEnvironment('KEEPSY_TRACE');

final Stopwatch _sinceStart = Stopwatch()..start();
final Random _rng = Random();
final bool _kInFlutterTest = Platform.environment.containsKey('FLUTTER_TEST');
int _seq = 0;

abstract class Trace {
  static bool? _override;

  @visibleForTesting
  static set debugEnabled(bool? value) => _override = value;

  static bool get enabled {
    final value = _override;
    if (value != null) return value;
    if (_kTraceDefined) return _kTraceOverride;
    if (_kInFlutterTest) return false;
    return kDebugMode;
  }

  static String newTraceId() {
    final b = StringBuffer();
    for (var i = 0; i < 8; i++) {
      b.write(_rng.nextInt(0x10000).toRadixString(16).padLeft(4, '0'));
    }
    return b.toString();
  }

  static const Object _zoneKey = #keepsyTraceId;

  static String? get currentId => Zone.current[_zoneKey] as String?;

  // Avoid Zone overhead on hot paths when tracing is disabled
  static Future<T> withId<T>(String traceId, Future<T> Function() body) {
    if (!enabled) return body();
    return runZoned(body, zoneValues: {_zoneKey: traceId});
  }

  // Use fixed reasons because exception messages can contain signed URLs
  static String reasonOf(Object error) {
    final type = error.runtimeType.toString();
    final message = error.toString().toLowerCase();
    for (final entry in _kReasonVocabulary.entries) {
      if (message.contains(entry.key)) return '${type}_${entry.value}';
    }
    return type;
  }

  static String id(String? value) {
    if (value == null || value.isEmpty) return '-';
    return value.length <= 8 ? value : value.substring(0, 8);
  }

  // Signed URLs and WebSocket tickets live in the query string
  static String url(String? raw) {
    if (raw == null || raw.isEmpty) return '-';
    final uri = Uri.tryParse(raw);
    if (uri == null) return 'unparseable';
    return '${uri.scheme}://${uri.authority}${uri.path}';
  }

  static void event(String name, {Map<String, Object?> fields = const {}}) {
    if (!enabled) return;
    _emit(name, null, {'tid': currentId, ...fields});
  }

  static TraceSpan start(
    String name, {
    String? traceId,
    Map<String, Object?> fields = const {},
  }) {
    if (!enabled) return TraceSpan._disabled();
    final resolvedTraceId = traceId ?? currentId;
    final span = TraceSpan._(name, resolvedTraceId, fields);
    _emit('$name.start', null, {...fields, 'tid': resolvedTraceId});
    return span;
  }

  static Future<T> measure<T>(
    String name,
    Future<T> Function() operation, {
    Map<String, Object?> fields = const {},
    Map<String, Object?> Function(T result)? endFields,
  }) async {
    if (!enabled) return operation();
    final span = start(name, fields: fields);
    try {
      final result = await operation();
      span.end(fields: endFields?.call(result) ?? const {});
      return result;
    } catch (error) {
      span.fail(reasonOf(error));
      rethrow;
    }
  }

  static T measureSync<T>(
    String name,
    T Function() operation, {
    Map<String, Object?> fields = const {},
    Map<String, Object?> Function(T result)? endFields,
  }) {
    if (!enabled) return operation();
    final span = start(name, fields: fields);
    try {
      final result = operation();
      span.end(fields: endFields?.call(result) ?? const {});
      return result;
    } catch (error) {
      span.fail(reasonOf(error));
      rethrow;
    }
  }
}

class TraceSpan {
  final String _name;
  final String? _traceId;
  final Map<String, Object?> _base;
  final Stopwatch? _watch;
  bool _closed = false;

  TraceSpan._(this._name, this._traceId, this._base)
      : _watch = (Stopwatch()..start());

  TraceSpan._disabled()
      : _name = '',
        _traceId = null,
        _base = const {},
        _watch = null,
        _closed = true;

  int get elapsedMs => _watch?.elapsedMilliseconds ?? 0;

  void end({Map<String, Object?> fields = const {}}) =>
      _finish('$_name.end', fields);

  void fail(String reason, {Map<String, Object?> fields = const {}}) =>
      _finish('$_name.fail', {...fields, 'reason': reason});

  void _finish(String event, Map<String, Object?> fields) {
    if (_closed) return;
    _closed = true;
    _watch!.stop();
    if (!Trace.enabled) return;
    _emit(event, _watch.elapsedMilliseconds, {
      ..._base,
      ...fields,
      'tid': _traceId,
    });
  }
}

void _emit(String name, int? durMs, Map<String, Object?> fields) {
  final b = StringBuffer()
    ..write(kTracePrefix)
    ..write('|')
    ..write(_seq++)
    ..write('|t=')
    ..write(_sinceStart.elapsedMilliseconds)
    ..write('|')
    ..write(name);
  if (durMs != null) b.write('|dur=$durMs');
  fields.forEach((key, value) {
    if (value != null) b.write(' $key=${_scrub(value)}');
  });
  // ignore: avoid_print
  print(b.toString());
}

const Map<String, String> _kReasonVocabulary = {
  'connection closed before full header': 'halfopen',
  'connection reset by peer': 'peerreset',
  'software caused connection abort': 'abort',
  'broken pipe': 'brokenpipe',
  'connection refused': 'refused',
  'connection timed out': 'conntimeout',
  'operation timed out': 'optimeout',
  'no route to host': 'noroute',
  'network is unreachable': 'unreachable',
  'failed host lookup': 'dns',
  'timeoutexception': 'deadline',
};

String _scrub(Object value) => value.toString().replaceAll(RegExp(r'\s+'), '_');
