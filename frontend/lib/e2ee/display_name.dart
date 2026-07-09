import 'dart:convert';
import 'dart:typed_data';

import 'package:keepsy/crypto/uuid_bytes.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/sealed_name.dart';

// PUT /albums/{id}/members/me/profile-ct with the sealed name_ct. The server
// resolves the caller's member_token from middleware, so no token is passed
typedef PutProfileCt = Future<void> Function(String albumId, String nameCtB64);

// One album the caller belongs to, for member name fan out. member_token is
// needed only to build the member name AAD (not the API call)
typedef NameTarget = ({String albumId, Uint8List memberToken});

// Publishes the user's global display name into albums, sealed under each
// album's current MK. No per album override in this pass
class DisplayNamePublisher {
  final AlbumKeyStore _ks;
  final PutProfileCt _putProfileCt;

  DisplayNamePublisher({
    required AlbumKeyStore ks,
    required PutProfileCt putProfileCt,
  })  : _ks = ks,
        _putProfileCt = putProfileCt;

  // No op when the name is empty or the album has no MK yet (latestEpoch == -1)
  Future<void> publishToAlbum({
    required String albumId,
    required Uint8List memberToken,
    required String name,
  }) async {
    if (name.isEmpty) return;
    final idBytes = uuidToBytes(albumId);
    if (idBytes == null) return;
    final epoch = await _ks.latestEpoch(idBytes);
    if (epoch < 0) return;
    final ct =
        await SealedName.sealMemberName(_ks, idBytes, memberToken, epoch, name);
    await _putProfileCt(albumId, ct);
  }

  // Best effort fan out across every album the user is in. A failure on one
  // album doesn't abort the rest
  Future<void> publishToAll(Iterable<NameTarget> targets, String name) async {
    if (name.isEmpty) return;
    for (final t in targets) {
      try {
        await publishToAlbum(
            albumId: t.albumId, memberToken: t.memberToken, name: name);
      } catch (_) {
        // keep going : the other albums should still get updated
      }
    }
  }
}

// Resolves an album's stored name_ct to a display string. Not part of the
// crypto primitive : it also handles the pre release legacy placeholder
// (base64(utf8(name))) and the fallback title
Future<String> resolveAlbumName(
    AlbumKeyStore ks, Uint8List albumId, String? nameCtB64) async {
  if (nameCtB64 == null || nameCtB64.isEmpty) return 'Untitled Album';
  final opened = await SealedName.openAlbumName(ks, albumId, nameCtB64);
  if (opened != null) return opened;
  // openAlbumName also returns null for a real sealed title whose MK isn't
  // installed yet : dont run the legacy utf8 decode on those (it could flash
  // mojibake). Only decode blobs that dont look like a sealed envelope
  Uint8List raw;
  try {
    raw = base64.decode(nameCtB64);
  } catch (_) {
    return 'Untitled Album';
  }
  if (!_looksSealed(raw)) {
    try {
      final decoded = utf8.decode(raw, allowMalformed: false);
      if (decoded.isNotEmpty) return decoded;
    } catch (_) {
      // not legacy plaintext either
    }
  }
  return 'Untitled Album';
}

// A sealed name is u32_be(epoch) || VER || NONCE(12) || TAG(16) || CT. Legacy
// placeholders are just base64(utf8(name)) and wont match this shape
bool _looksSealed(Uint8List raw) {
  if (raw.length < 4 + kHeaderLen) return false;
  final ver = raw[4];
  return ver == kVerAesGcm || ver == kVerChaPo || ver == kVerStreamGcm;
}
