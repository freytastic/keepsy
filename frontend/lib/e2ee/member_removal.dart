import 'dart:async';
import 'dart:typed_data';

import 'epoch_rotator.dart';

// Revoke must commit before rotation so wraps target only the remaining set

typedef RevokeMemberFn = Future<bool> Function(
    Uint8List albumId, Uint8List memberToken);
typedef ActiveTokensFn = Future<List<Uint8List>> Function(Uint8List albumId);
typedef CurrentEpochFn = Future<int> Function(Uint8List albumId);
typedef RotateFn = Future<void> Function(
    Uint8List albumId, int epoch, List<RotateRecipient> recipients);
// Missing or changed recipient pins must fail rotation before MK creation
typedef ExpectedIkFn = Future<Uint8List> Function(
    Uint8List albumId, Uint8List memberToken);
typedef DropDirectoryFn = void Function(
    Uint8List albumId, Uint8List memberToken);
typedef WipeLocalAlbumFn = Future<void> Function(Uint8List albumId);
typedef IsRotationRequiredFn = Future<bool> Function(Uint8List albumId);

class MemberRemovalException implements Exception {
  final String message;
  const MemberRemovalException(this.message);
  @override
  String toString() => 'MemberRemovalException($message)';
}

class MemberRemovalCoordinator {
  final RevokeMemberFn _revoke;
  final ActiveTokensFn _activeTokens;
  final CurrentEpochFn _currentEpoch;
  final RotateFn _rotate;
  final ExpectedIkFn _expectedIk;
  final DropDirectoryFn _dropDirectory;
  final WipeLocalAlbumFn _wipeLocalAlbum;
  final IsRotationRequiredFn _isRotationRequired;

  // One rotation chain per album
  final Map<String, Future<void>> _rotations = {};

  MemberRemovalCoordinator({
    required RevokeMemberFn revoke,
    required ActiveTokensFn activeTokens,
    required CurrentEpochFn currentEpoch,
    required RotateFn rotate,
    required ExpectedIkFn expectedIk,
    required DropDirectoryFn dropDirectory,
    required WipeLocalAlbumFn wipeLocalAlbum,
    required IsRotationRequiredFn isRotationRequired,
  })  : _revoke = revoke,
        _activeTokens = activeTokens,
        _currentEpoch = currentEpoch,
        _rotate = rotate,
        _expectedIk = expectedIk,
        _dropDirectory = dropDirectory,
        _wipeLocalAlbum = wipeLocalAlbum,
        _isRotationRequired = isRotationRequired;

  // Revoke first so the recovery rotation excludes the removed member
  Future<void> kick(Uint8List albumId, Uint8List memberToken) async {
    if (!await _revoke(albumId, memberToken)) {
      throw const MemberRemovalException('revoke failed');
    }
    await recoverIfPending(albumId);
    _dropDirectory(albumId, memberToken);
  }

  // The leaver wipes locally and leaves recovery rotation to the admin
  Future<void> leave(Uint8List albumId, Uint8List selfToken) async {
    if (!await _revoke(albumId, selfToken)) {
      throw const MemberRemovalException('revoke failed');
    }
    await _wipeLocalAlbum(albumId);
  }

  // Serialized so queued callers recheck after any earlier rotation commits
  Future<bool> recoverIfPending(Uint8List albumId) =>
      _serial(albumId, () => _rotateIfRequired(albumId));

  Future<void> onSelfRemoved(Uint8List albumId) => _wipeLocalAlbum(albumId);

  void onOtherRemoved(Uint8List albumId, Uint8List memberToken) =>
      _dropDirectory(albumId, memberToken);

  Future<bool> _rotateIfRequired(Uint8List albumId) async {
    if (!await _isRotationRequired(albumId)) return false;
    try {
      await _rotateForActiveSet(albumId);
      return true;
    } catch (_) {
      // A rotation committed elsewhere wins the epoch race and settles the debt
      bool stillRequired;
      try {
        stillRequired = await _isRotationRequired(albumId);
      } catch (_) {
        stillRequired = true;
      }
      if (stillRequired) rethrow;
      return false;
    }
  }

  Future<void> _rotateForActiveSet(Uint8List albumId) async {
    final active = await _activeTokens(albumId);
    final next = (await _currentEpoch(albumId)) + 1;
    // Resolve every pinned recipient key before generating the new MK
    final recipients = <RotateRecipient>[];
    for (final t in active) {
      recipients.add(RotateRecipient(
          memberToken: t, expectedIk: await _expectedIk(albumId, t)));
    }
    await _rotate(albumId, next, recipients);
  }

  Future<T> _serial<T>(Uint8List albumId, Future<T> Function() body) async {
    final key = _hex(albumId);
    final prev = _rotations[key];
    final done = Completer<void>();
    _rotations[key] = done.future;
    try {
      if (prev != null) await prev;
      return await body();
    } finally {
      done.complete();
      if (identical(_rotations[key], done.future)) _rotations.remove(key);
    }
  }
}

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
