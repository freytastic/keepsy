import 'dart:typed_data';

import 'package:keepsy/secure_store/key_handle.dart';
import 'package:keepsy/secure_store/secure_key_store.dart';

// MK_epoch store keyed on (albumId, epoch). Persists each MK under a fixed
// label scheme (D6) so re init can rebuild the in memory presence map by
// listing the SecureKeyStore. Replay/downgrade rule lives in installVerified
// (spec §7.3) : useMk<T> is the ONLY public surface for MK bytes (D2)

const String kAlbumLabelPrefix = 'keepsy.album.';

class AlbumKeyStore {
  final SecureKeyStore _store;

  // hex(albumId) -> { epoch -> KeyHandle }
  final Map<String, Map<int, KeyHandle>> _present = {};
  bool _initialized = false;

  AlbumKeyStore(this._store);

  // Rebuilds presence from any keepsy.album.<hex>.mk.<epoch> labels already
  // in the SecureKeyStore. Idempotent
  Future<void> initialize() async {
    final handles = await _store.list(labelPrefix: kAlbumLabelPrefix);
    _present.clear();
    for (final h in handles) {
      final parsed = _parseLabel(h.label);
      if (parsed == null) continue;
      _present.putIfAbsent(parsed.albumHex, () => {})[parsed.epoch] = h;
    }
    _initialized = true;
  }

  Future<int> latestEpoch(Uint8List albumId) async {
    _requireInit();
    final m = _present[_hex(albumId)];
    if (m == null || m.isEmpty) return -1;
    return m.keys.reduce((a, b) => a > b ? a : b);
  }

  Future<List<int>> presentEpochs(Uint8List albumId) async {
    _requireInit();
    final m = _present[_hex(albumId)];
    if (m == null) return const [];
    return m.keys.toList()..sort();
  }

  // Direct write : bypasses replay/downgrade. Internal flows + tests only
  Future<void> install(Uint8List albumId, int epoch, Uint8List mk) async {
    _requireInit();
    if (epoch < 0) throw ArgumentError('epoch must be >= 0, got $epoch');
    if (mk.length != 32) {
      throw ArgumentError('mk must be 32 bytes, got ${mk.length}');
    }
    final hex = _hex(albumId);
    final label = '$kAlbumLabelPrefix$hex.mk.$epoch';
    final h = await _store.put(label, mk);
    _present.putIfAbsent(hex, () => {})[epoch] = h;
  }

  // Replay/downgrade rule (spec §7.3). Idempotent on byte equal re install
  Future<void> installVerified({
    required Uint8List albumId,
    required int epoch,
    required Uint8List mk,
    required bool backfill,
  }) async {
    _requireInit();
    if (epoch < 0) throw ArgumentError('epoch must be >= 0, got $epoch');
    if (mk.length != 32) {
      throw ArgumentError('mk must be 32 bytes, got ${mk.length}');
    }
    final hex = _hex(albumId);
    final existing = _present[hex]?[epoch];
    if (existing != null) {
      // Idempotent on byte equal, tamper exception otherwise. Read existing
      // through use<T> so the bytes get zeroed in the finally
      final equal = await _store.use<bool>(existing, (bytes) async {
        if (bytes.length != mk.length) return false;
        var diff = 0;
        for (var i = 0; i < bytes.length; i++) {
          diff |= bytes[i] ^ mk[i];
        }
        return diff == 0;
      });
      if (equal) return;
      throw EpochReplayException(
        epoch: epoch,
        latestEpoch: await latestEpoch(albumId),
        reason: 'tamper',
      );
    }

    final latest = await latestEpoch(albumId);
    if (epoch < latest && !backfill) {
      throw EpochReplayException(
        epoch: epoch,
        latestEpoch: latest,
        reason: 'downgrade',
      );
    }
    await install(albumId, epoch, mk);
  }

  // Only public surface for MK bytes (D2). Mirrors SecureKeyStore.use<T> :
  // bytes zeroed in finally, callback style so nothing escapes
  Future<T> useMk<T>(
    Uint8List albumId,
    int epoch,
    Future<T> Function(Uint8List mk) fn,
  ) {
    _requireInit();
    final h = _present[_hex(albumId)]?[epoch];
    if (h == null) {
      throw StateError('no MK for album=${_hex(albumId)} epoch=$epoch');
    }
    return _store.use<T>(h, fn);
  }

  void _requireInit() {
    if (!_initialized) {
      throw StateError('AlbumKeyStore.initialize() must be called first');
    }
  }
}

class EpochReplayException implements Exception {
  final int epoch;
  final int latestEpoch;
  final String reason; // 'downgrade' | 'tamper'
  const EpochReplayException({
    required this.epoch,
    required this.latestEpoch,
    required this.reason,
  });
  @override
  String toString() =>
      'EpochReplayException($reason, epoch=$epoch, latest=$latestEpoch)';
}

// keepsy.album.<hex32>.mk.<epoch>
final RegExp _kLabelRe = RegExp(r'^keepsy\.album\.([0-9a-f]{32})\.mk\.(\d+)$');

({String albumHex, int epoch})? _parseLabel(String label) {
  final m = _kLabelRe.firstMatch(label);
  if (m == null) return null;
  return (albumHex: m.group(1)!, epoch: int.parse(m.group(2)!));
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
