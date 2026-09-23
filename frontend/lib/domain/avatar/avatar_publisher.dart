import 'dart:async';
import 'dart:typed_data';

import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/e2ee/sealed_avatar.dart';

// Unknown is not the same as removed: only an explicit removal may delete
// avatars from the server, never a missing or unreadable local record
enum OwnAvatarState { unknown, set, removed }

abstract class OwnAvatar {
  OwnAvatarState get state;
  Uint8List? get jpeg;
  // Changes with every new photo, making every album's copy stale at once
  String? get revision;
  String? publishedTo(String albumId);
  Future<void> markPublished(String albumId, String avatarId, String revision);
}

// Null while the album has no key installed on this phone yet
typedef SealAvatar = Future<SealedAvatar?> Function(
    String albumId, String memberToken, Uint8List jpeg);
typedef UploadAvatar = Future<void> Function(
    String albumId, SealedAvatar avatar);
typedef RemoveAvatar = Future<void> Function(String albumId);

// Converges every album on the user's current avatar by comparing what each
// listing shows for our own token. Failed albums are retried by the next one
class AvatarPublisher {
  final OwnAvatar _own;
  final SealAvatar _seal;
  final UploadAvatar _upload;
  final RemoveAvatar _remove;
  final List<AlbumModel> Function() _albums;

  Future<void>? _running;
  bool _again = false;
  bool _stopped = false;

  AvatarPublisher({
    required OwnAvatar own,
    required SealAvatar seal,
    required UploadAvatar upload,
    required RemoveAvatar remove,
    required List<AlbumModel> Function() albums,
  })  : _own = own,
        _seal = seal,
        _upload = upload,
        _remove = remove,
        _albums = albums;

  // Requests landing mid run collapse into one more pass over the newest shelf
  Future<void> sync() {
    if (_stopped) return Future.value();
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _drain();
  }

  Future<void> stop() async {
    _stopped = true;
    final running = _running;
    if (running != null) await running;
  }

  Future<void> _drain() async {
    try {
      do {
        _again = false;
        for (final album in List<AlbumModel>.of(_albums())) {
          if (_stopped) return;
          try {
            await _converge(album);
          } catch (_) {
            // The next listing sees this album unchanged and tries again
          }
        }
      } while (_again && !_stopped);
    } finally {
      _running = null;
    }
  }

  Future<void> _converge(AlbumModel album) async {
    final token = album.memberToken;
    // A thin listing cannot say what the album currently shows for us
    if (!album.hasSummary || token == null) return;
    final self =
        album.memberPreviews.where((m) => m.memberToken == token).firstOrNull;
    if (self == null) return;
    final shown = self.avatar?.avatarId;

    switch (_own.state) {
      case OwnAvatarState.unknown:
        return;
      case OwnAvatarState.removed:
        if (shown != null) await _remove(album.id);
      case OwnAvatarState.set:
        if (shown != null && shown == _own.publishedTo(album.id)) return;
        final jpeg = _own.jpeg;
        final revision = _own.revision;
        if (jpeg == null || revision == null) return;
        final sealed = await _seal(album.id, token, jpeg);
        if (sealed == null) return;
        await _upload(album.id, sealed);
        await _own.markPublished(album.id, sealed.avatarId, revision);
    }
  }
}
