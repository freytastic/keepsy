// Crockford base32 keepsy_id, mirror of server/internal/handle. Folding +
// validation MUST stay byte-identical to the Go Normalize (cross lang vectors
// in handle_test.dart). No I/L/O/U: I/L fold to 1, O folds to 0

const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const handleLength = 8;

// Folds a user entered handle to canonical form : drop dashes + whitespace,
// upper case, fold ambiguous chars (I/L→1, O→0), validate length + alphabet
// Throws [FormatException] on anything that isnt a valid 8 char handle
String normalizeHandle(String input) {
  final out = StringBuffer();
  for (final rune in input.runes) {
    var c = rune;
    if (c == 0x2D || c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
      continue; // dash / space / tab / newline / CR
    }
    if (c >= 0x61 && c <= 0x7A) c -= 0x20; // ASCII lower → upper
    if (c == 0x49 || c == 0x4C) {
      c = 0x31; // I, L → 1
    } else if (c == 0x4F) {
      c = 0x30; // O → 0
    }
    final ch = String.fromCharCode(c);
    if (!_alphabet.contains(ch)) {
      throw const FormatException('invalid keepsy_id handle');
    }
    out.write(ch);
    if (out.length > handleLength) {
      throw const FormatException('invalid keepsy_id handle');
    }
  }
  if (out.length != handleLength) {
    throw const FormatException('invalid keepsy_id handle');
  }
  return out.toString();
}

/// Display form XXXX-XXXX. Storage + the wire always use the canonical value
String formatHandle(String canonical) {
  if (canonical.length != handleLength) return canonical;
  return '${canonical.substring(0, 4)}-${canonical.substring(4)}';
}
