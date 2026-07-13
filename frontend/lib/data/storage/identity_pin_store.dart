import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';

// TOFU state, sealed under cache_root_key like the name/media caches
// Two maps with deliberately different keys :

//   pins      (albumId, memberToken) -> ik_pub last seen for that roster slot
//             member_token is the stable pseudonymous handle, so a DIFFERENT
//             ik_pub under the SAME token is exactly the key change signal
//   verified  (myIkPub, peerIkPub) -> when. "this device identity confirmed
//             that peer identity key". Not album scoped : reading 30 digits to
//             a fren confirms their KEY, which is the same key in every album
//             you share. Binding our own IK in too keeps a future second device
//             (or another account on this phone) from inheriting the claim

// UNLIKE the name/media caches this MUST survive logout : if a logout reset the
// pins, a hostile server could sit on a new ik_pub until the user logs out once
// and then present it as an innocent first sight. Only a revoke/leave
// (clearAlbum) or a full account reset (clear) may drop it
class IdentityPinStore {
  final File _file;
  final Uint8List _cacheKey;
  final Map<String, String> _pins = {}; // 'albumId:token' -> base64 ik_pub
  final Map<String, int> _verified = {}; // 'b64(myIk)|b64(peerIk)' -> unix s
  Timer? _flushTimer;
  int _gen = 0;
  Future<void> _inFlight = Future.value();

  static final Uint8List _aad =
      Uint8List.fromList('keepsy.identity-pins-v1'.codeUnits);

  IdentityPinStore._(this._file, this._cacheKey);

  static Future<IdentityPinStore> open({
    File? file,
    required Uint8List cacheRootKey,
  }) async {
    final f = file ??
        File(p.join(
            (await getApplicationSupportDirectory()).path, 'keepsy_pins.kec'));
    final s = IdentityPinStore._(f, cacheRootKey);
    await s._load();
    return s;
  }

  Uint8List? pinnedIk(String albumId, String memberToken) {
    final b64 = _pins[_pinKey(albumId, memberToken)];
    return b64 == null ? null : base64.decode(b64);
  }

  void pin(String albumId, String memberToken, Uint8List ikPub) {
    final k = _pinKey(albumId, memberToken);
    final v = base64.encode(ikPub);
    if (_pins[k] == v) return;
    _pins[k] = v;
    _scheduleFlush();
  }

  bool isVerified({required Uint8List myIkPub, required Uint8List peerIkPub}) =>
      _verified.containsKey(_vKey(myIkPub, peerIkPub));

  void markVerified(
      {required Uint8List myIkPub,
      required Uint8List peerIkPub,
      DateTime? at}) {
    final k = _vKey(myIkPub, peerIkPub);
    if (_verified.containsKey(k)) return;
    _verified[k] = (at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    _scheduleFlush();
  }

  DateTime? verifiedAt(
      {required Uint8List myIkPub, required Uint8List peerIkPub}) {
    final s = _verified[_vKey(myIkPub, peerIkPub)];
    return s == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true);
  }

  // Revoke / leave / album delete. Drops the roster pins we can no longer
  // refresh, but NOT the verifications : "that key is really his" stays true
  Future<void> clearAlbum(String albumId) async {
    final prefix = '$albumId:';
    final before = _pins.length;
    _pins.removeWhere((k, _) => k.startsWith(prefix));
    if (_pins.length == before) return;
    _gen++;
    _flushTimer?.cancel();
    try {
      await _inFlight;
    } catch (_) {}
    await flush();
  }

  // Full account reset only : NOT called on a normal logout (see class note)
  Future<void> clear() async {
    _gen++;
    _flushTimer?.cancel();
    _pins.clear();
    _verified.clear();
    try {
      await _inFlight;
    } catch (_) {}
    await _delete(_file);
    await _delete(File('${_file.path}.tmp'));
  }

  Future<void> _load() async {
    try {
      if (!await _file.exists()) return;
      final wire = await _file.readAsBytes();
      final pt = await Aead.decrypt(wire: wire, key: _cacheKey, aad: _aad);
      final map = jsonDecode(utf8.decode(pt)) as Map<String, dynamic>;
      _pins.clear();
      _verified.clear();
      (map['p'] as Map<String, dynamic>? ?? {})
          .forEach((k, v) => _pins[k] = v as String);
      (map['v'] as Map<String, dynamic>? ?? {})
          .forEach((k, v) => _verified[k] = v as int);
    } catch (_) {
      // missing / corrupt / key mismatch : start empty. A lost pin degrades to
      // a first sight (TOFU), never to a false "verified"
      _pins.clear();
      _verified.clear();
    }
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(flush());
    });
  }

  Future<void> flush() {
    _flushTimer?.cancel();
    final gen = _gen;
    _inFlight = _inFlight.then((_) => _write(gen));
    return _inFlight;
  }

  Future<void> _write(int gen) async {
    if (gen != _gen) return;
    try {
      final pt = Uint8List.fromList(
          utf8.encode(jsonEncode({'p': _pins, 'v': _verified})));
      final sealed = await Aead.encrypt(
          version: kVerAesGcm, key: _cacheKey, plaintext: pt, aad: _aad);
      if (gen != _gen) return;
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsBytes(sealed, flush: true);
      if (gen != _gen) {
        await _delete(tmp);
        return;
      }
      await tmp.rename(_file.path);
    } catch (_) {
      // a failed write re TOFUs next session : never silently "verified"
    }
  }

  Future<void> _delete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  static String _pinKey(String albumId, String memberToken) =>
      '$albumId:$memberToken';

  static String _vKey(Uint8List myIkPub, Uint8List peerIkPub) =>
      '${base64.encode(myIkPub)}|${base64.encode(peerIkPub)}';
}
