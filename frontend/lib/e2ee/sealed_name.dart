import 'dart:convert';
import 'dart:typed_data';

import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/e2ee/album_keys.dart';

// Display names (album title + member name) sealed under the album MK. The MK
// rotates per epoch and every member retains all epoch MKs, so the epoch the
// name was sealed under travels inside the blob : the reader knows which MK to
// use, and no DB migration is needed (name_ct stays an opaque column)

//   nameWire = u32_be(epoch) || VER||NONCE||TAG||CT
//   name_ct  = base64(nameWire)

// AAD binds each blob to its slot so a name cant be replayed into another
class SealedName {
  static final Uint8List _albumTag =
      Uint8List.fromList('keepsy.album-name-v1'.codeUnits);
  static final Uint8List _memberTag =
      Uint8List.fromList('keepsy.member-name-v1'.codeUnits);

  static Future<String> sealAlbumName(
      AlbumKeyStore ks, Uint8List albumId, int epoch, String name) {
    return _seal(ks, albumId, epoch, name, _albumNameAad(albumId, epoch));
  }

  static Future<String> sealMemberName(AlbumKeyStore ks, Uint8List albumId,
      Uint8List memberToken, int epoch, String name) {
    return _seal(
        ks, albumId, epoch, name, _memberNameAad(albumId, memberToken, epoch));
  }

  // Returns null on any failure (malformed blob, missing MK for that epoch,
  // auth fail). Callers render a fallback
  static Future<String?> openAlbumName(
      AlbumKeyStore ks, Uint8List albumId, String nameCtB64) {
    return _open(
        ks, albumId, nameCtB64, (epoch) => _albumNameAad(albumId, epoch));
  }

  static Future<String?> openMemberName(AlbumKeyStore ks, Uint8List albumId,
      Uint8List memberToken, String nameCtB64) {
    return _open(ks, albumId, nameCtB64,
        (epoch) => _memberNameAad(albumId, memberToken, epoch));
  }

  // Batch variant : decrypts many members' names with ONE keystore unwrap per
  // epoch (members usually share the current epoch) instead of one useMk per
  // member. Returns { token -> name } for entries that decrypt : missing ones
  // (no MK yet, malformed, auth-fail) are simply absent. Order independent
  static Future<Map<String, String>> openMemberNames(
    AlbumKeyStore ks,
    Uint8List albumId,
    List<({String token, Uint8List tokenBytes, String nameCt})> items,
  ) async {
    // Group parsed blobs by the epoch encoded in each so we unwrap each MK once
    final byEpoch =
        <int, List<({String token, Uint8List tokenBytes, Uint8List blob})>>{};
    for (final it in items) {
      Uint8List wire;
      try {
        wire = base64.decode(it.nameCt);
      } catch (_) {
        continue;
      }
      if (wire.length < 4) continue;
      final epoch = _readU32be(wire, 0);
      byEpoch.putIfAbsent(epoch, () => []).add((
        token: it.token,
        tokenBytes: it.tokenBytes,
        blob: Uint8List.sublistView(wire, 4),
      ));
    }

    final out = <String, String>{};
    for (final entry in byEpoch.entries) {
      final epoch = entry.key;
      try {
        await ks.useMk<void>(albumId, epoch, (mk) async {
          for (final p in entry.value) {
            final aad = _memberNameAad(albumId, p.tokenBytes, epoch);
            try {
              final pt = await Aead.decrypt(wire: p.blob, key: mk, aad: aad);
              out[p.token] = utf8.decode(pt);
            } catch (_) {
              // malformed / auth-fail : leave this one unresolved
            }
          }
        });
      } catch (_) {
        // no MK for this epoch yet : those members stay unresolved
      }
    }
    return out;
  }

  static Future<String> _seal(AlbumKeyStore ks, Uint8List albumId, int epoch,
      String name, Uint8List aad) async {
    if (epoch < 0) throw ArgumentError('epoch must be >= 0, got $epoch');
    final pt = Uint8List.fromList(utf8.encode(name));
    final blob = await ks.useMk<Uint8List>(
        albumId,
        epoch,
        (mk) => Aead.encrypt(
            version: kVerAesGcm, key: mk, plaintext: pt, aad: aad));
    final out = Uint8List(4 + blob.length);
    _writeU32be(out, 0, epoch);
    out.setRange(4, out.length, blob);
    return base64.encode(out);
  }

  static Future<String?> _open(AlbumKeyStore ks, Uint8List albumId,
      String nameCtB64, Uint8List Function(int epoch) aadFor) async {
    try {
      final wire = base64.decode(nameCtB64);
      if (wire.length < 4) return null;
      final epoch = _readU32be(wire, 0);
      final blob = Uint8List.sublistView(wire, 4);
      final aad = aadFor(epoch);
      return await ks.useMk<String?>(albumId, epoch, (mk) async {
        try {
          final pt = await Aead.decrypt(wire: blob, key: mk, aad: aad);
          return utf8.decode(pt);
        } on AeadAuthFailed {
          return null;
        } on FormatException {
          return null;
        }
      });
    } catch (_) {
      // base64 decode error, or no MK installed for that epoch (useMk throws)
      return null;
    }
  }

  static Uint8List _albumNameAad(Uint8List albumId, int epoch) {
    return _concat([_albumTag, albumId, _u32be(epoch)]);
  }

  static Uint8List _memberNameAad(
      Uint8List albumId, Uint8List memberToken, int epoch) {
    return _concat([_memberTag, albumId, memberToken, _u32be(epoch)]);
  }
}

Uint8List _u32be(int v) {
  final b = Uint8List(4);
  _writeU32be(b, 0, v);
  return b;
}

void _writeU32be(Uint8List out, int offset, int v) {
  out[offset] = (v >> 24) & 0xff;
  out[offset + 1] = (v >> 16) & 0xff;
  out[offset + 2] = (v >> 8) & 0xff;
  out[offset + 3] = v & 0xff;
}

int _readU32be(Uint8List b, int offset) {
  return (b[offset] << 24) |
      (b[offset + 1] << 16) |
      (b[offset + 2] << 8) |
      b[offset + 3];
}

Uint8List _concat(List<Uint8List> parts) {
  var len = 0;
  for (final p in parts) {
    len += p.length;
  }
  final out = Uint8List(len);
  var off = 0;
  for (final p in parts) {
    out.setRange(off, off + p.length, p);
    off += p.length;
  }
  return out;
}
