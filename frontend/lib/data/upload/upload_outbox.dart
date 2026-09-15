import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/uuid_bytes.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';

class OutboxRecord {
  final String itemId;
  final String albumId;
  final String mediaId;
  final int payloadByteLength;
  final Uint8List? thumbPreview;
  const OutboxRecord({
    required this.itemId,
    required this.albumId,
    required this.mediaId,
    required this.payloadByteLength,
    this.thumbPreview,
  });
}

// Seals each photo to its owning account rather than an album key, so rotations
// cannot strand it and another login cannot publish it
class UploadOutboxStore {
  final Directory _dir;
  final Uint8List _key;

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9-]{1,64}$');

  UploadOutboxStore._(this._dir, this._key);

  static Future<UploadOutboxStore> open({
    Directory? dir,
    required Uint8List cacheRootKey,
  }) async {
    final d = dir ??
        Directory(p.join(
            (await getApplicationSupportDirectory()).path, 'keepsy_outbox'));
    await d.create(recursive: true);
    final store = UploadOutboxStore._(d, cacheRootKey);
    await store._sweepUncommitted();
    return store;
  }

  // Metadata lands last, so its presence is the commit marker
  Future<void> put({
    required String itemId,
    required String albumId,
    required String owner,
    required EncryptedMedia media,
  }) async {
    _checkId(itemId);
    await _write(_file(itemId, 'file'), media.cipherBytes);
    final thumb = media.thumbCipherBytes;
    if (thumb != null) await _write(_file(itemId, 'thumb'), thumb);
    final thumbSha = media.thumbSha256;
    final thumbDek = media.thumbDek;
    final plain = Uint8List.fromList(utf8.encode(jsonEncode({
      'v': 1,
      'owner': owner,
      'album': albumId,
      'media': uuidFromBytes(media.mediaId),
      'type': media.mediaType,
      'mime': media.mimeType,
      'sha': base64Encode(media.blobSha256),
      'dek': base64Encode(media.dek),
      if (thumb != null && thumbSha != null && thumbDek != null) ...{
        'tsha': base64Encode(thumbSha),
        'tdek': base64Encode(thumbDek),
      },
      'at': DateTime.now().toUtc().toIso8601String(),
    })));
    try {
      final sealed = await Aead.encrypt(
          version: kVerAesGcm, key: _key, plaintext: plain, aad: _aad(itemId));
      await _write(_file(itemId, 'meta'), sealed);
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  Future<EncryptedMedia?> load(String itemId, {required String owner}) async {
    if (!_idPattern.hasMatch(itemId)) return null;
    final meta = await _openMeta(itemId);
    if (meta == null || meta['owner'] != owner) return null;
    try {
      final cipher = await _file(itemId, 'file').readAsBytes();
      final thumbFile = _file(itemId, 'thumb');
      final tdek = meta['tdek'] as String?;
      final thumb = tdek != null && thumbFile.existsSync()
          ? await thumbFile.readAsBytes()
          : null;
      final sha = base64Decode(meta['sha'] as String);
      if (!_ctEq(await _sha256(cipher), sha)) return null;
      return EncryptedMedia(
        mediaId: uuidToBytes(meta['media'] as String)!,
        cipherBytes: cipher,
        blobSha256: sha,
        dek: base64Decode(meta['dek'] as String),
        mediaType: meta['type'] as String,
        mimeType: meta['mime'] as String?,
        thumbCipherBytes: thumb,
        thumbSha256:
            thumb == null ? null : base64Decode(meta['tsha'] as String),
        thumbDek: thumb == null ? null : base64Decode(tdek!),
      );
    } catch (_) {
      return null;
    }
  }

  // Removes entries owned by another login and defers blob hashing until load
  Future<List<OutboxRecord>> restore(String owner) async {
    final found = <({DateTime at, OutboxRecord record})>[];
    for (final id in await _committedIds()) {
      final meta = await _openMeta(id);
      final file = _file(id, 'file');
      if (meta == null || meta['owner'] != owner || !file.existsSync()) {
        await remove(id);
        continue;
      }
      try {
        var payload = await file.length();
        Uint8List? preview;
        final thumbFile = _file(id, 'thumb');
        final tdek = meta['tdek'] as String?;
        if (tdek != null && thumbFile.existsSync()) {
          final thumb = await thumbFile.readAsBytes();
          payload += thumb.length;
          final dek = base64Decode(tdek);
          try {
            preview = await FilePipeline.openThumbCipher(
                mediaId: uuidToBytes(meta['media'] as String)!,
                cipher: thumb,
                dek: dek);
          } catch (_) {
          } finally {
            dek.fillRange(0, dek.length, 0);
          }
        }
        found.add((
          at: DateTime.tryParse(meta['at'] as String? ?? '') ?? DateTime(0),
          record: OutboxRecord(
            itemId: id,
            albumId: meta['album'] as String,
            mediaId: meta['media'] as String,
            payloadByteLength: payload,
            thumbPreview: preview,
          ),
        ));
      } catch (_) {
        await remove(id);
      }
    }
    found.sort((a, b) => a.at.compareTo(b.at));
    return [for (final f in found) f.record];
  }

  // Metadata goes first so an interrupted removal leaves sweepable blobs
  Future<void> remove(String itemId) async {
    if (!_idPattern.hasMatch(itemId)) return;
    for (final ext in const ['meta', 'file', 'thumb']) {
      await _delete(_file(itemId, ext));
    }
  }

  Future<void> clearAlbum(String albumId) async {
    for (final id in await _committedIds()) {
      final meta = await _openMeta(id);
      if (meta == null || meta['album'] == albumId) await remove(id);
    }
  }

  // An unreadable record counts because clearAlbum already tried to delete it
  Future<bool> holdsAlbum(String albumId) async {
    for (final id in await _committedIds()) {
      final meta = await _openMeta(id);
      if (meta == null || meta['album'] == albumId) return true;
    }
    return false;
  }

  Future<void> clearAll() async {
    if (!await _dir.exists()) return;
    await for (final entry in _dir.list()) {
      if (entry is File) await _delete(entry);
    }
  }

  Future<List<String>> _committedIds() async {
    final ids = <String>[];
    if (!await _dir.exists()) return ids;
    await for (final entry in _dir.list()) {
      if (entry is! File || p.extension(entry.path) != '.meta') continue;
      ids.add(p.basenameWithoutExtension(entry.path));
    }
    return ids;
  }

  Future<Map<String, dynamic>?> _openMeta(String itemId) async {
    final f = _file(itemId, 'meta');
    try {
      if (!f.existsSync()) return null;
      final plain = await Aead.decrypt(
          wire: await f.readAsBytes(), key: _key, aad: _aad(itemId));
      try {
        return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      } finally {
        plain.fillRange(0, plain.length, 0);
      }
    } catch (_) {
      return null;
    }
  }

  Future<void> _sweepUncommitted() async {
    final committed = (await _committedIds()).toSet();
    await for (final entry in _dir.list()) {
      if (entry is! File) continue;
      final ext = p.extension(entry.path);
      final id = p.basenameWithoutExtension(entry.path);
      if (ext == '.tmp' || (ext != '.meta' && !committed.contains(id))) {
        await _delete(entry);
      }
    }
  }

  File _file(String itemId, String ext) =>
      File(p.join(_dir.path, '$itemId.$ext'));

  void _checkId(String itemId) {
    if (!_idPattern.hasMatch(itemId)) {
      throw ArgumentError('unsafe outbox id: $itemId');
    }
  }

  // Binds each sealed meta to its own entry so metas cannot be swapped
  Uint8List _aad(String itemId) =>
      Uint8List.fromList(utf8.encode('keepsy.outbox-v1|$itemId'));

  Future<void> _write(File f, Uint8List bytes) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  Future<void> _delete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

Future<Uint8List> _sha256(Uint8List bytes) async =>
    Uint8List.fromList((await cg.Sha256().hash(bytes)).bytes);

bool _ctEq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}
