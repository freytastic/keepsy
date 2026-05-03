import 'dart:convert';
import 'dart:typed_data';

// Deterministic JSON byte representation : mirror of internal/crypto/canonical_json.go
// Any divergence between the two sides breaks every signature in flight

// Rules :
//   object keys sorted by raw UTF-8 byte order, ascending
//   no insignificant whitespace
//   strings : only " and \ escaped, control chars 0x00..0x1F as \uXXXX,
//             non-ASCII characters preserved as raw UTF-8 (never \uXXXX-escaped)
//   integers : decimal, no leading zero, no trailing dot
//   floats are rejected : this protocol carries only integer fields
//   accepted types : null, bool, int, String, List, Map<String, ...>

// Callers must pre normalize Unicode (NFC) before passing strings : the
// serializer itself never normalizes, to keep both sides byte identical
// without depending on Unicode tables that may diverge
abstract class CanonicalJson {
  static Uint8List encode(Object? v) {
    final sb = StringBuffer();
    _writeValue(sb, v);
    return Uint8List.fromList(utf8.encode(sb.toString()));
  }

  static String encodeString(Object? v) {
    final sb = StringBuffer();
    _writeValue(sb, v);
    return sb.toString();
  }

  static void _writeValue(StringBuffer sb, Object? v) {
    if (v == null) {
      sb.write('null');
    } else if (v is bool) {
      sb.write(v ? 'true' : 'false');
    } else if (v is int) {
      sb.write(v.toString());
    } else if (v is double) {
      throw ArgumentError('canonical JSON rejects floats');
    } else if (v is String) {
      _writeString(sb, v);
    } else if (v is List) {
      sb.write('[');
      for (var i = 0; i < v.length; i++) {
        if (i > 0) sb.write(',');
        _writeValue(sb, v[i]);
      }
      sb.write(']');
    } else if (v is Map) {
      // Keys must all be strings : sort by raw UTF-8 byte order
      final keys = <String>[];
      v.forEach((k, _) {
        if (k is! String) {
          throw ArgumentError(
              'canonical JSON requires string keys, got ${k.runtimeType}');
        }
        keys.add(k);
      });
      keys.sort(_utf8ByteCompare);
      sb.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) sb.write(',');
        _writeString(sb, keys[i]);
        sb.write(':');
        _writeValue(sb, v[keys[i]]);
      }
      sb.write('}');
    } else {
      throw ArgumentError(
          'canonical JSON does not support type ${v.runtimeType}');
    }
  }

  static int _utf8ByteCompare(String a, String b) {
    final ab = utf8.encode(a);
    final bb = utf8.encode(b);
    final n = ab.length < bb.length ? ab.length : bb.length;
    for (var i = 0; i < n; i++) {
      if (ab[i] != bb[i]) return ab[i] - bb[i];
    }
    return ab.length - bb.length;
  }

  static void _writeString(StringBuffer sb, String s) {
    sb.write('"');
    // Iterate by code units so we can detect surrogates and emit raw UTF-8
    // for the assembled BMP/non-BMP characters via writeCharCode
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      switch (c) {
        case 0x22: // "
          sb.write(r'\"');
          break;
        case 0x5C: // backslash
          sb.write(r'\\');
          break;
        case 0x08:
          sb.write(r'\b');
          break;
        case 0x0C:
          sb.write(r'\f');
          break;
        case 0x0A:
          sb.write(r'\n');
          break;
        case 0x0D:
          sb.write(r'\r');
          break;
        case 0x09:
          sb.write(r'\t');
          break;
        default:
          if (c < 0x20) {
            sb.write('\\u');
            sb.write(c.toRadixString(16).padLeft(4, '0'));
          } else {
            sb.writeCharCode(c);
          }
      }
    }
    sb.write('"');
  }
}
