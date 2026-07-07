import 'dart:typed_data';

import 'epoch_rotator.dart';

// MemberRemovalCoordinator : the client side orchestration of member removal
// Kept out of the UI layer and driven by injected ports so
// the order sensitive logic is unit testable : the screens/composition root
// wire the real API + rotator + cache closures

// The one invariant that must never break is revoke-before-rotate: the server's
// epoch drift check only accepts a rotation whose recipient set equals the live
// active set, and the removed member drops out of that set only once revoked

typedef RevokeMemberFn = Future<bool> Function(
    Uint8List albumId, Uint8List memberToken);
typedef ActiveTokensFn = Future<List<Uint8List>> Function(Uint8List albumId);
typedef CurrentEpochFn = Future<int> Function(Uint8List albumId);
typedef RotateFn = Future<void> Function(
    Uint8List albumId, int epoch, List<RotateRecipient> recipients);
typedef DropDirectoryFn = void Function(
    Uint8List albumId, Uint8List memberToken);
typedef WipeLocalAlbumFn = Future<void> Function(Uint8List albumId);
typedef IsPendingRotationFn = Future<bool> Function(Uint8List albumId);

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
  final DropDirectoryFn _dropDirectory;
  final WipeLocalAlbumFn _wipeLocalAlbum;
  final IsPendingRotationFn _isPendingRotation;

  MemberRemovalCoordinator({
    required RevokeMemberFn revoke,
    required ActiveTokensFn activeTokens,
    required CurrentEpochFn currentEpoch,
    required RotateFn rotate,
    required DropDirectoryFn dropDirectory,
    required WipeLocalAlbumFn wipeLocalAlbum,
    required IsPendingRotationFn isPendingRotation,
  })  : _revoke = revoke,
        _activeTokens = activeTokens,
        _currentEpoch = currentEpoch,
        _rotate = rotate,
        _dropDirectory = dropDirectory,
        _wipeLocalAlbum = wipeLocalAlbum,
        _isPendingRotation = isPendingRotation;

  // admin removes another member. Revoke, then rotate to the next epoch
  // for the (now smaller) active set so new content is sealed under a key the
  // removed member never receives, then drop them from the member directory
  Future<void> kick(Uint8List albumId, Uint8List memberToken) async {
    if (!await _revoke(albumId, memberToken)) {
      throw const MemberRemovalException('revoke failed');
    }
    await _rotateForActiveSet(albumId);
    _dropDirectory(albumId, memberToken);
  }

  // self removal. Revoke, then wipe this album's local data (MKs +
  // cache + list entry). The leaver deliberately does NOT rotate : minting the
  // key the remaining members will hold is the admin's job, deferred to the
  // pending rotation recovery
  Future<void> leave(Uint8List albumId, Uint8List selfToken) async {
    if (!await _revoke(albumId, selfToken)) {
      throw const MemberRemovalException('revoke failed');
    }
    await _wipeLocalAlbum(albumId);
  }

  // called when an admin opens an album. If the album is in
  // the transient window between a revoke and its rotation (a crashed kick or a
  // deferred leave), finish the rotation for the current active set. Returns
  // whether a rotation was performed
  Future<bool> recoverIfPending(Uint8List albumId) async {
    if (!await _isPendingRotation(albumId)) return false;
    await _rotateForActiveSet(albumId);
    return true;
  }

  // this device learned it was removed from an album by someone
  // else (member_revoked event or a 403). No server call : just drop the local
  // data so nothing under the album's keys survives
  Future<void> onSelfRemoved(Uint8List albumId) => _wipeLocalAlbum(albumId);

  // another member was removed. Evict them from the directory
  // so the next roster lookup re fetches and sees them gone
  void onOtherRemoved(Uint8List albumId, Uint8List memberToken) =>
      _dropDirectory(albumId, memberToken);

  Future<void> _rotateForActiveSet(Uint8List albumId) async {
    final active = await _activeTokens(albumId);
    final next = (await _currentEpoch(albumId)) + 1;
    await _rotate(albumId, next, [
      for (final t in active) RotateRecipient(memberToken: t),
    ]);
  }
}
