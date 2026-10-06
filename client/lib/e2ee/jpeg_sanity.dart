import 'dart:typed_data';

// Keeps JPEG picture segments and removes metadata and trailing payloads

const int _kSoi = 0xD8;
const int _kEoi = 0xD9;
const int _kSos = 0xDA;
const int _kApp0 = 0xE0;
const int _kApp15 = 0xEF;
const int _kCom = 0xFE;
const int _kTem = 0x01;
const int _kRst0 = 0xD0;
const int _kRst7 = 0xD7;

// Segments that describe how to reconstruct the pixels
const Set<int> _kStructural = {
  0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
  0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
  0xC4, // DHT
  0xCC, // DAC
  0xDB, // DQT
  0xDC, // DNL
  0xDD, // DRI
  0xDE, // DHP
  0xDF, // EXP
};

bool _isFrame(int marker) =>
    marker >= 0xC0 &&
    marker <= 0xCF &&
    marker != 0xC4 &&
    marker != 0xC8 &&
    marker != 0xCC;

// Keep only a fixed JFIF header with no embedded thumbnail
bool _isBareJfif(Uint8List b, int start, int length) {
  if (length != 16) return false;
  const id = [0x4A, 0x46, 0x49, 0x46, 0x00];
  for (var i = 0; i < id.length; i++) {
    if (b[start + i] != id[i]) return false;
  }
  return b[start + 12] == 0 && b[start + 13] == 0;
}

class SanitizedJpeg {
  final Uint8List bytes;
  // Metadata markers removed for the upload trace
  final List<int> stripped;
  const SanitizedJpeg({required this.bytes, required this.stripped});
}

abstract class JpegSanity {
  // Returns a complete metadata-free JPEG or null
  static SanitizedJpeg? sanitize(Uint8List b) {
    if (b.length < 4 || b[0] != 0xFF || b[1] != _kSoi) return null;

    final out = BytesBuilder();
    final stripped = <int>[];
    out.add(const [0xFF, _kSoi]);

    var i = 2;
    var sawFrame = false;
    var sawScan = false;

    while (i < b.length) {
      if (b[i] != 0xFF) return null;
      // Fill bytes are legal padding before a marker
      while (i < b.length && b[i] == 0xFF) {
        i++;
      }
      if (i >= b.length) return null;
      final marker = b[i];
      i++;

      if (marker == _kEoi) {
        // Reject payloads hidden after the end marker
        if (!sawFrame || !sawScan || i != b.length) return null;
        out.add(const [0xFF, _kEoi]);
        return SanitizedJpeg(bytes: out.toBytes(), stripped: stripped);
      }
      if (marker == _kTem || (marker >= _kRst0 && marker <= _kRst7)) {
        out.add([0xFF, marker]);
        continue;
      }
      if (marker == _kSoi) return null;

      if (i + 1 >= b.length) return null;
      final length = (b[i] << 8) | b[i + 1];
      if (length < 2) return null;
      final payload = i + 2;
      final next = i + length;
      if (next > b.length) return null;

      if (marker == _kCom || (marker >= _kApp0 && marker <= _kApp15)) {
        if (marker == _kApp0 && _isBareJfif(b, payload, length)) {
          out.add([0xFF, marker]);
          out.add(Uint8List.sublistView(b, i, next));
        } else {
          stripped.add(marker);
        }
      } else if (marker == _kSos) {
        // Walk entropy data through stuffed bytes and restart markers
        final end = _skipScan(b, next);
        if (end < 0) return null;
        out.add([0xFF, marker]);
        out.add(Uint8List.sublistView(b, i, end));
        sawScan = true;
        i = end;
        continue;
      } else if (_kStructural.contains(marker)) {
        out.add([0xFF, marker]);
        out.add(Uint8List.sublistView(b, i, next));
        if (_isFrame(marker)) sawFrame = true;
      } else {
        return null;
      }

      i = next;
    }
    // Ran out of bytes without an end marker
    return null;
  }

  static bool isClean(Uint8List b) {
    final s = sanitize(b);
    return s != null && s.stripped.isEmpty;
  }

  // Describe structural failures without logging payload bytes
  static String describe(Uint8List b) {
    final seen = <String>[];
    if (b.length < 4) return 'short:${b.length}';
    if (b[0] != 0xFF || b[1] != _kSoi) {
      return 'not_soi:${b[0].toRadixString(16)}${b[1].toRadixString(16)}';
    }
    var i = 2;
    while (i < b.length) {
      if (b[i] != 0xFF) return '${seen.join(',')}|not_marker@$i';
      while (i < b.length && b[i] == 0xFF) {
        i++;
      }
      if (i >= b.length) return '${seen.join(',')}|ends_on_fill';
      final marker = b[i];
      i++;
      seen.add(marker.toRadixString(16));
      if (marker == _kEoi) {
        return '${seen.join(',')}|eoi@$i/${b.length}';
      }
      if (marker == _kTem || (marker >= _kRst0 && marker <= _kRst7)) continue;
      if (i + 1 >= b.length) return '${seen.join(',')}|truncated_len';
      final length = (b[i] << 8) | b[i + 1];
      if (length < 2) return '${seen.join(',')}|bad_len:$length';
      final next = i + length;
      if (next > b.length) {
        return '${seen.join(',')}|len_past_end:$length';
      }
      if (marker == _kSos) {
        final end = _skipScan(b, next);
        if (end < 0) return '${seen.join(',')}|scan_unterminated';
        i = end;
        continue;
      }
      i = next;
    }
    return '${seen.join(',')}|no_eoi';
  }

  // Find the marker that ends this entropy scan
  static int _skipScan(Uint8List b, int from) {
    var i = from;
    while (i + 1 < b.length) {
      if (b[i] != 0xFF) {
        i++;
        continue;
      }
      final next = b[i + 1];
      if (next == 0x00 || next == 0xFF) {
        i++;
        continue;
      }
      if (next >= _kRst0 && next <= _kRst7) {
        i += 2;
        continue;
      }
      return i;
    }
    return -1;
  }
}
