import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/models/album_summary.dart';
import 'package:keepsy/data/models/avatar_ref.dart';
import 'package:keepsy/domain/avatar/avatar_publisher.dart';
import 'package:keepsy/e2ee/sealed_avatar.dart';

class _Own implements OwnAvatar {
  @override
  OwnAvatarState state = OwnAvatarState.unknown;
  @override
  Uint8List? jpeg;
  @override
  String? revision;
  final Map<String, String> published = {};

  void set(String rev) {
    state = OwnAvatarState.set;
    jpeg = Uint8List.fromList([1, 2, 3]);
    revision = rev;
    published.clear();
  }

  @override
  String? publishedTo(String albumId) => published[albumId];

  @override
  Future<void> markPublished(
      String albumId, String avatarId, String revision) async {
    if (revision == this.revision) published[albumId] = avatarId;
  }
}

AvatarRef _ref(String id) => AvatarRef(
    avatarId: id,
    blobSize: kAvatarBlobBytes,
    blobSha256: Uint8List(32),
    keyCt: Uint8List(65));

AlbumModel _album(String id,
        {String? shown, bool summary = true, String self = 'me'}) =>
    AlbumModel(
      id: id,
      nameCt: null,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      memberToken: self,
      hasSummary: summary,
      memberPreviews: [
        MemberPreview(
            memberToken: 'me', avatar: shown == null ? null : _ref(shown)),
        MemberPreview(memberToken: 'friend', avatar: _ref('theirs')),
      ],
    );

class _Harness {
  final own = _Own();
  List<AlbumModel> albums = [];
  final uploads = <(String, String)>[];
  final removals = <String>[];
  final noKey = <String>{};
  final failing = <String>{};
  var minted = 0;
  Completer<void>? gate;

  late final publisher = AvatarPublisher(
    own: own,
    albums: () => albums,
    seal: (albumId, token, jpeg) async {
      if (noKey.contains(albumId)) return null;
      return SealedAvatar(
          avatarId: 'copy-${++minted}',
          blob: Uint8List(0),
          blobSha256: Uint8List(32),
          keyCt: Uint8List(65));
    },
    upload: (albumId, sealed) async {
      await gate?.future;
      if (failing.contains(albumId)) throw Exception('offline');
      uploads.add((albumId, sealed.avatarId));
    },
    remove: (albumId) async => removals.add(albumId),
  );
}

void main() {
  test('uploads to every album that does not show the current photo', () async {
    final h = _Harness()..own.set('r1');
    h.albums = [_album('a'), _album('b', shown: 'old')];
    await h.publisher.sync();

    expect(h.uploads.map((u) => u.$1), ['a', 'b']);
    expect(h.own.published, {'a': 'copy-1', 'b': 'copy-2'});
  });

  test('an album already showing its published copy is left alone', () async {
    final h = _Harness()..own.set('r1');
    h.own.published['a'] = 'copy-a';
    h.albums = [_album('a', shown: 'copy-a')];
    await h.publisher.sync();
    expect(h.uploads, isEmpty);
  });

  test('a copy the server dropped is published again', () async {
    final h = _Harness()..own.set('r1');
    h.own.published['a'] = 'copy-a';
    h.albums = [_album('a')];
    await h.publisher.sync();
    expect(h.uploads.single.$1, 'a');
  });

  test('skips thin listings and albums without a key yet', () async {
    final h = _Harness()..own.set('r1');
    h.noKey.add('locked');
    h.albums = [_album('thin', summary: false), _album('locked')];
    await h.publisher.sync();
    expect(h.uploads, isEmpty);
    expect(h.own.published, isEmpty);
  });

  test('one failing album does not stop the others', () async {
    final h = _Harness()..own.set('r1');
    h.failing.add('a');
    h.albums = [_album('a'), _album('b')];
    await h.publisher.sync();
    expect(h.uploads.map((u) => u.$1), ['b']);
    expect(h.own.published.keys, ['b']);
  });

  test('removal deletes only where an avatar is showing', () async {
    final h = _Harness()..own.state = OwnAvatarState.removed;
    h.albums = [_album('a', shown: 'x'), _album('b')];
    await h.publisher.sync();
    expect(h.removals, ['a']);
  });

  test('an unknown local state never touches the server', () async {
    final h = _Harness();
    h.albums = [_album('a', shown: 'x'), _album('b')];
    await h.publisher.sync();
    expect(h.uploads, isEmpty);
    expect(h.removals, isEmpty);
  });

  test('a photo changed mid upload is published in a follow up pass', () async {
    final h = _Harness()..own.set('r1');
    h.albums = [_album('a')];
    h.gate = Completer<void>();
    final first = h.publisher.sync();
    await Future<void>.delayed(Duration.zero);

    h.own.set('r2');
    final second = h.publisher.sync();
    h.gate!.complete();
    await Future.wait([first, second]);

    expect(h.uploads.length, 2);
    expect(h.own.published['a'], h.uploads.last.$2);
  });

  test('stop waits for the running pass and blocks new ones', () async {
    final h = _Harness()..own.set('r1');
    h.albums = [_album('a')];
    h.gate = Completer<void>();
    final running = h.publisher.sync();
    await Future<void>.delayed(Duration.zero);
    final stopped = h.publisher.stop();
    h.gate!.complete();
    await Future.wait([running, stopped]);

    h.albums = [_album('b')];
    await h.publisher.sync();
    expect(h.uploads.map((u) => u.$1), ['a']);
  });

  // A pass over an empty shelf finishes without awaiting anything, which must
  // not leave the publisher believing a pass is still running
  test('a sync over no albums does not block the next one', () async {
    final h = _Harness()..own.set('r1');
    await h.publisher.sync();

    h.albums = [_album('a')];
    await h.publisher.sync();
    expect(h.uploads.map((u) => u.$1), ['a']);
  });
}
