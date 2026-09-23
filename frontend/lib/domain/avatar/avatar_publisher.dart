import 'dart:async';
import 'dart:typed_data';

import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/diagnostics/trace.dart';
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
    Trace.event('avatar.sync', fields: {
      'state': _own.state.name,
      'albums': _albums().length,
      'stopped': _stopped,
      'queued': _running != null,
    });
    if (_stopped) return Future.value();
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    // Cleared by a callback, not inside _drain: a pass over an empty shelf
    // completes synchronously, before it could be recorded as running
    final run = _drain();
    _running = run;
    run.whenComplete(() {
      if (identical(_running, run)) _running = null;
    });
    return run;
  }

  Future<void> stop() async {
    _stopped = true;
    final running = _running;
    if (running != null) await running;
  }

  Future<void> _drain() async {
    do {
      _again = false;
      for (final album in List<AlbumModel>.of(_albums())) {
        if (_stopped) return;
        try {
          await _converge(album);
        } catch (e) {
          // The next listing sees this album unchanged and tries again
          Trace.event('avatar.failed', fields: {
            'album': Trace.id(album.id),
            'reason': Trace.reasonOf(e)
          });
        }
      }
    } while (_again && !_stopped);
  }

  Future<void> _converge(AlbumModel album) async {
    void skip(String why) => Trace.event('avatar.skip',
        fields: {'album': Trace.id(album.id), 'why': why});

    final token = album.memberToken;
    // A thin listing cannot say what the album currently shows for us
    if (!album.hasSummary || token == null) return skip('thin');
    final self =
        album.memberPreviews.where((m) => m.memberToken == token).firstOrNull;
    if (self == null) return skip('not_listed');
    final shown = self.avatar?.avatarId;

    switch (_own.state) {
      case OwnAvatarState.unknown:
        return skip('unknown');
      case OwnAvatarState.removed:
        if (shown == null) return skip('removed');
        await Trace.measure('avatar.remove', () => _remove(album.id),
            fields: {'album': Trace.id(album.id)});
      case OwnAvatarState.set:
        if (shown != null && shown == _own.publishedTo(album.id)) {
          return skip('current');
        }
        final jpeg = _own.jpeg;
        final revision = _own.revision;
        if (jpeg == null || revision == null) return skip('no_photo');
        final sealed = await _seal(album.id, token, jpeg);
        if (sealed == null) return skip('no_key');
        await Trace.measure('avatar.publish', () => _upload(album.id, sealed),
            fields: {'album': Trace.id(album.id)});
        await _own.markPublished(album.id, sealed.avatarId, revision);
    }
  }
}
