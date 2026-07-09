import 'dart:typed_data';

// Canonical 8-4-4-4-12 hex form for a raw 16B UUID
String uuidFromBytes(Uint8List b) {
  if (b.length != 16) {
    throw ArgumentError('uuid must be 16 bytes, got ${b.length}');
  }
  final s = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
      '-${s.substring(16, 20)}-${s.substring(20)}';
}

// Raw 16B form of a canonical UUID string. Returns null on malformed input
Uint8List? uuidToBytes(String s) {
  final hex = s.replaceAll('-', '');
  if (hex.length != 32) return null;
  final out = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    final v = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (v == null) return null;
    out[i] = v;
  }
  return out;
}
