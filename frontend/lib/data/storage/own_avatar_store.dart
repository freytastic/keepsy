import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/domain/avatar/avatar_publisher.dart';

// The user's own avatar plus which copy each album holds. A new photo starts
// a new revision, which makes every album's copy stale at once
class OwnAvatarStore extends ChangeNotifier implements OwnAvatar {
  final File _file;
  final Uint8List _cacheKey;

  OwnAvatarState _state = OwnAvatarState.unknown;
  String? _revision;
  Uint8List? _jpeg;
  final Map<String, String> _published = {};
  Future<void> _writes = Future.value();

  static final Uint8List _aad =
      Uint8List.fromList('keepsy.own-avatar-v1'.codeUnits);

  OwnAvatarStore._(this._file, this._cacheKey);

  static Future<OwnAvatarStore> open({
    File? file,
    required Uint8List cacheRootKey,
  }) async {
    final f = file ??
        File(p.join((await getApplicationSupportDirectory()).path,
            'keepsy_avatar.kec'));
    final s = OwnAvatarStore._(f, cacheRootKey);
    await s._load();
    return s;
  }

  @override
  OwnAvatarState get state => _state;
  @override
  Uint8List? get jpeg => _jpeg;
  @override
  String? get revision => _revision;

  @override
  String? publishedTo(String albumId) => _published[albumId];

  Future<void> set(Uint8List jpeg) {
    _state = OwnAvatarState.set;
    _revision = const Uuid().v4();
    _jpeg = jpeg;
    _published.clear();
    notifyListeners();
    return _persist();
  }

  Future<void> remove() {
    _state = OwnAvatarState.removed;
    _revision = null;
    _jpeg = null;
    _published.clear();
    notifyListeners();
    return _persist();
  }

  // Ignored when the photo changed while this copy was uploading
  @override
  Future<void> markPublished(
      String albumId, String avatarId, String revision) async {
    if (revision != _revision) return;
    _published[albumId] = avatarId;
    await _persist();
  }

  Future<void> forgetAlbum(String albumId) async {
    if (_published.remove(albumId) != null) await _persist();
  }

  Future<void> wipe() async {
    _state = OwnAvatarState.unknown;
    _revision = null;
    _jpeg = null;
    _published.clear();
    notifyListeners();
    final pending = _writes;
    _writes = Future.value();
    try {
      await pending;
    } catch (_) {}
    for (final f in [_file, File('${_file.path}.tmp')]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  Future<void> _load() async {
    try {
      if (!await _file.exists()) return;
      final pt = await Aead.decrypt(
          wire: await _file.readAsBytes(), key: _cacheKey, aad: _aad);
      final j = jsonDecode(utf8.decode(pt)) as Map<String, dynamic>;
      final photo = j['jpeg'] as String?;
      _state = j['removed'] == true
          ? OwnAvatarState.removed
          : photo == null
              ? OwnAvatarState.unknown
              : OwnAvatarState.set;
      _revision = j['rev'] as String?;
      _jpeg = photo == null ? null : base64.decode(photo);
      (j['published'] as Map<String, dynamic>? ?? {})
          .forEach((k, v) => _published[k] = v as String);
    } catch (_) {
      // Unreadable stays unknown, so nothing is removed on its account
    }
  }

  // Serialized so an older snapshot can never land after a newer one
  Future<void> _persist() {
    final snapshot = jsonEncode({
      if (_state == OwnAvatarState.removed) 'removed': true,
      if (_revision != null) 'rev': _revision,
      if (_jpeg != null) 'jpeg': base64.encode(_jpeg!),
      'published': Map.of(_published),
    });
    // A failed write must not stall the ones queued behind it
    return _writes = _writes.catchError((_) {}).then((_) async {
      final sealed = await Aead.encrypt(
        version: kVerAesGcm,
        key: _cacheKey,
        plaintext: Uint8List.fromList(utf8.encode(snapshot)),
        aad: _aad,
      );
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsBytes(sealed, flush: true);
      await tmp.rename(_file.path);
    });
  }
}
