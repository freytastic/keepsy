import 'dart:typed_data';

import 'package:keepsy/e2ee/media_record.dart';

// Security groups identity and access changes; Albums groups content
enum ActivityLane { security, albums }

// Album history ages out; security history remains as the access record
const Duration kActivityWindow = Duration(days: 90);

sealed class ActivityEvent {
  // Stable across re-derivation, so one upload cannot become a new row on
  // every launch
  final String id;
  final String albumId;
  final DateTime at;

  const ActivityEvent({
    required this.id,
    required this.albumId,
    required this.at,
  });

  ActivityLane get lane;

  bool get needsDecision => false;
}

// A pinned peer identity no longer matches what the server serves
class SafetyNumberChanged extends ActivityEvent {
  final String peerToken;
  // Exact key that raised the alarm; Compare must not reread a mutable roster
  // Null only for legacy rows
  final Uint8List? presentedIk;
  final bool verified;
  const SafetyNumberChanged({
    required super.id,
    required super.albumId,
    required super.at,
    required this.peerToken,
    this.presentedIk,
    this.verified = false,
  });

  SafetyNumberChanged asVerified() => SafetyNumberChanged(
        id: id,
        albumId: albumId,
        at: at,
        peerToken: peerToken,
        presentedIk: presentedIk,
        verified: true,
      );

  @override
  ActivityLane get lane => ActivityLane.security;
  @override
  bool get needsDecision => true;
}

class InvitedToAlbum extends ActivityEvent {
  const InvitedToAlbum({
    required super.id,
    required super.albumId,
    required super.at,
  });

  @override
  ActivityLane get lane => ActivityLane.security;
  @override
  bool get needsDecision => true;
}

class RemovedFromAlbum extends ActivityEvent {
  const RemovedFromAlbum({
    required super.id,
    required super.albumId,
    required super.at,
  });

  @override
  ActivityLane get lane => ActivityLane.security;
  @override
  bool get needsDecision => true;
}

class MemberJoined extends ActivityEvent {
  final String memberToken;
  const MemberJoined({
    required super.id,
    required super.albumId,
    required super.at,
    required this.memberToken,
  });

  @override
  ActivityLane get lane => ActivityLane.security;
}

class MemberLeft extends ActivityEvent {
  final String memberToken;
  // Revocation commits before recovery rotation, which may remain owed
  // The row must not promise a rotation that has not happened
  final bool rotationPending;
  const MemberLeft({
    required super.id,
    required super.albumId,
    required super.at,
    required this.memberToken,
    this.rotationPending = false,
  });

  @override
  ActivityLane get lane => ActivityLane.security;

  MemberLeft settled() => MemberLeft(
        id: id,
        albumId: albumId,
        at: at,
        memberToken: memberToken,
      );
}

// uploaderToken is null until a media fetch attributes it: the shelf summary
// says how many arrived but never who sent them
class PhotosAdded extends ActivityEvent {
  final int count;
  final String? uploaderToken;
  // The uploader's newest few, so the row can show the photos themselves
  // Kept whole because a thumbnail cannot be opened without its wrap
  final List<MediaRecord> previews;
  const PhotosAdded({
    required super.id,
    required super.albumId,
    required super.at,
    required this.count,
    this.uploaderToken,
    this.previews = const [],
  });

  @override
  ActivityLane get lane => ActivityLane.albums;
}
