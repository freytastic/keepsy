import 'dart:async';
import 'dart:typed_data';

import 'package:keepsy/secure_store/key_handle.dart';
import 'package:keepsy/secure_store/secure_key_store.dart';

const String kAlbumLabelPrefix = 'keepsy.album.';

class AlbumKeyStore {
  final SecureKeyStore _store;

  // hex(albumId) -> { epoch -> KeyHandle }
  final Map<String, Map<int, KeyHandle>> _present = {};
  Future<void>? _initFuture;

  AlbumKeyStore(this._store);

  Future<void> initialize() {
    return _initFuture ??= _rebuildPresence().catchError((Object e) {
      _initFuture = null;
      throw e;
    });
  }

  Future<void> _rebuildPresence() async {
    final handles = await _store.list(labelPrefix: kAlbumLabelPrefix);
    _present.clear();
    for (final h in handles) {
      final parsed = _parseLabel(h.label);
      if (parsed == null) continue;
      _present.putIfAbsent(parsed.albumHex, () => {})[parsed.epoch] = h;
    }
  }

  Future<int> latestEpoch(Uint8List albumId) async {
    await initialize();
    final m = _present[_hex(albumId)];
    if (m == null || m.isEmpty) return -1;
    return m.keys.reduce((a, b) => a > b ? a : b);
  }

  Future<List<int>> presentEpochs(Uint8List albumId) async {
    await initialize();
    final m = _present[_hex(albumId)];
    if (m == null) return const [];
    return m.keys.toList()..sort();
  }

  // Bypasses replay and downgrade checks
  Future<void> install(Uint8List albumId, int epoch, Uint8List mk) async {
    await initialize();
    if (epoch < 0) throw ArgumentError('epoch must be >= 0, got $epoch');
    if (mk.length != 32) {
      throw ArgumentError('mk must be 32 bytes, got ${mk.length}');
    }
    if (_closed) throw StateError('album key store is closed');
    final hex = _hex(albumId);
    final label = '$kAlbumLabelPrefix$hex.mk.$epoch';
    final h = await _store.put(label, mk);
    _present.putIfAbsent(hex, () => {})[epoch] = h;
  }

  // Reinstalling an epoch requires identical key bytes
  Future<void> installVerified({
    required Uint8List albumId,
    required int epoch,
    required Uint8List mk,
    required bool backfill,
  }) async {
    await initialize();
    if (epoch < 0) throw ArgumentError('epoch must be >= 0, got $epoch');
    if (mk.length != 32) {
      throw ArgumentError('mk must be 32 bytes, got ${mk.length}');
    }
    final hex = _hex(albumId);
    final existing = _present[hex]?[epoch];
    if (existing != null) {
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

  bool _closed = false;

  // Closing first prevents a late install from recreating wiped key state
  void forgetAll() {
    _closed = true;
    _present.clear();
  }

  Future<void> deleteAlbumMKs(Uint8List albumId) async {
    await initialize();
    final hex = _hex(albumId);
    final handles = _present[hex];
    if (handles == null) return;
    // Keep failed deletions in the map for retry
    for (final epoch in handles.keys.toList()) {
      await _store.delete(handles[epoch]!);
      handles.remove(epoch);
    }
    _present.remove(hex);
  }

  // Overlapping callbacks share one MK read until the last callback releases it
  Future<T> useMk<T>(
    Uint8List albumId,
    int epoch,
    Future<T> Function(Uint8List mk) fn,
  ) async {
    await initialize();
    final h = _present[_hex(albumId)]?[epoch];
    if (h == null) {
      throw StateError('no MK for album=${_hex(albumId)} epoch=$epoch');
    }
    final key = '${_hex(albumId)}.$epoch';
    final read = _reads[key] ??= _SharedRead(_store, h, (r) {
      if (identical(_reads[key], r)) _reads.remove(key);
    });
    return read.run(fn);
  }

  final Map<String, _SharedRead> _reads = {};
}

class _SharedRead {
  final Completer<Uint8List> _bytes = Completer<Uint8List>();
  final Completer<void> _released = Completer<void>();
  final void Function(_SharedRead) _onClose;
  late final Future<void> _finished;
  int _users = 0;
  bool _closed = false;

  _SharedRead(SecureKeyStore store, KeyHandle h, this._onClose) {
    _finished = store.use<void>(h, (bytes) async {
      _bytes.complete(bytes);
      // Returning releases the buffer to the store for zeroing
      await _released.future;
    }).catchError((Object e, StackTrace s) {
      if (!_bytes.isCompleted) _bytes.completeError(e, s);
      _close();
    });
  }

  Future<T> run<T>(Future<T> Function(Uint8List mk) fn) async {
    _users++;
    try {
      return await fn(await _bytes.future);
    } finally {
      if (--_users == 0) {
        _close();
        // Wait for zeroing before the last caller returns
        await _finished;
      }
    }
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    // Remove the shared read before releasing its buffer
    _onClose(this);
    _released.complete();
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

final RegExp _kLabelRe = RegExp(r'^keepsy\.album\.([0-9a-f]{32})\.mk\.(\d+)$');

({String albumHex, int epoch})? _parseLabel(String label) {
  final m = _kLabelRe.firstMatch(label);
  if (m == null) return null;
  return (albumHex: m.group(1)!, epoch: int.parse(m.group(2)!));
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
