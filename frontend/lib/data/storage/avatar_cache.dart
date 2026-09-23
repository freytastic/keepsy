import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/data/models/avatar_ref.dart';

// Downloads and opens one member's avatar. Null when it does not verify
typedef FetchAvatar = Future<Uint8List?> Function(
    String albumId, String memberToken, AvatarRef ref);

const Duration _retryAfter = Duration(minutes: 1);

// Decrypted avatars, resealed under the device cache key. One file per member,
// under hashed names so the directory does not reveal album ids or tokens
class AvatarCache extends ChangeNotifier {
  final Directory _root;
  final Uint8List _cacheKey;
  final FetchAvatar _fetch;

  final Map<String, ({String avatarId, Uint8List jpeg})> _memory = {};
  final Set<String> _loading = {};
  final Map<String, DateTime> _failedAt = {};
  // Bumped by every clear so an in flight load cannot write back afterwards
  int _gen = 0;

  static final Uint8List _aad =
      Uint8List.fromList('keepsy.avatar-cache-v1'.codeUnits);

  AvatarCache._(this._root, this._cacheKey, this._fetch);

  static Future<AvatarCache> open({
    Directory? root,
    required Uint8List cacheRootKey,
    required FetchAvatar fetch,
  }) async {
    final dir = root ??
        Directory(p.join((await getApplicationSupportDirectory()).path,
            'keepsy_vault', 'avatars'));
    return AvatarCache._(dir, cacheRootKey, fetch);
  }

  Uint8List? peek(String albumId, String memberToken, String avatarId) {
    final hit = _memory[_key(albumId, memberToken)];
    return hit != null && hit.avatarId == avatarId ? hit.jpeg : null;
  }

  // Safe to call from build: loads at most once per avatar and notifies later
  void ensure(String albumId, String memberToken, AvatarRef ref) {
    if (peek(albumId, memberToken, ref.avatarId) != null) return;
    if (_loading.contains(ref.avatarId)) return;
    final failed = _failedAt[ref.avatarId];
    if (failed != null && DateTime.now().difference(failed) < _retryAfter) {
      return;
    }
    _loading.add(ref.avatarId);
    unawaited(_load(albumId, memberToken, ref)
        .whenComplete(() => _loading.remove(ref.avatarId)));
  }

  Future<void> _load(String albumId, String memberToken, AvatarRef ref) async {
    final gen = _gen;
    try {
      final file = await _fileFor(albumId, memberToken);
      var jpeg = await _read(file, ref.avatarId);
      final fromDisk = jpeg != null;
      jpeg ??= await _fetch(albumId, memberToken, ref);
      if (gen != _gen) return;
      if (jpeg == null) {
        _failedAt[ref.avatarId] = DateTime.now();
        return;
      }
      _memory[_key(albumId, memberToken)] =
          (avatarId: ref.avatarId, jpeg: jpeg);
      _failedAt.remove(ref.avatarId);
      notifyListeners();
      if (!fromDisk) await _write(file, ref.avatarId, jpeg, gen);
    } catch (_) {
      _failedAt[ref.avatarId] = DateTime.now();
    }
  }

  Future<void> clearAlbum(String albumId) async {
    _gen++;
    _memory.removeWhere((k, _) => k.startsWith('$albumId|'));
    await _delete(await _albumDir(albumId));
    notifyListeners();
  }

  Future<void> clearAll() async {
    _gen++;
    _memory.clear();
    _failedAt.clear();
    await _delete(_root);
    notifyListeners();
  }

  Future<bool> holdsAlbum(String albumId) async =>
      _memory.keys.any((k) => k.startsWith('$albumId|')) ||
      await (await _albumDir(albumId)).exists();

  Future<Uint8List?> _read(File file, String avatarId) async {
    try {
      if (!await file.exists()) return null;
      final pt = await Aead.decrypt(
          wire: await file.readAsBytes(), key: _cacheKey, aad: _aad);
      final j = jsonDecode(utf8.decode(pt)) as Map<String, dynamic>;
      if (j['id'] != avatarId) return null;
      return base64.decode(j['jpeg'] as String);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(
      File file, String avatarId, Uint8List jpeg, int gen) async {
    try {
      final sealed = await Aead.encrypt(
        version: kVerAesGcm,
        key: _cacheKey,
        plaintext: Uint8List.fromList(utf8
            .encode(jsonEncode({'id': avatarId, 'jpeg': base64.encode(jpeg)}))),
        aad: _aad,
      );
      if (gen != _gen) return;
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(sealed, flush: true);
      if (gen != _gen) {
        await _delete(tmp);
        return;
      }
      await tmp.rename(file.path);
    } catch (_) {
      // The next session fetches it again
    }
  }

  Future<Directory> _albumDir(String albumId) async =>
      Directory(p.join(_root.path, await _hash('album:$albumId')));

  Future<File> _fileFor(String albumId, String memberToken) async =>
      File(p.join(
          (await _albumDir(albumId)).path, await _hash('member:$memberToken')));

  static String _key(String albumId, String memberToken) =>
      '$albumId|$memberToken';

  static Future<String> _hash(String s) async {
    final h = await cg.Sha256().hash(utf8.encode('keepsy.avatar-cache:$s'));
    return base64Url.encode(h.bytes).replaceAll('=', '');
  }

  static Future<void> _delete(FileSystemEntity e) async {
    try {
      if (await e.exists()) await e.delete(recursive: true);
    } catch (_) {}
  }
}
