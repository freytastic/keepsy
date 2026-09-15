import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/e2ee/rotation_recovery.dart';
import 'package:keepsy/ui/providers/app_state.dart';

AlbumModel _album(String id, {String? role}) => AlbumModel(
      id: id,
      nameCt: null,
      createdAt: DateTime.utc(2026, 9, 1),
      updatedAt: DateTime.utc(2026, 9, 1),
      myRole: role,
    );

RotationStatus _status(RotationPhase phase) =>
    RotationStatus(albumId: Uint8List(16), phase: phase);

void main() {
  group('viewer role', () {
    test('only the admin role may rotate', () {
      final s = AppState()
        ..setAlbums([
          _album('a1', role: 'admin'),
          _album('a2', role: 'member'),
          _album('a3', role: 'co-admin'),
        ]);
      expect(s.isAdminOf('a1'), isTrue);
      expect(s.isAdminOf('a2'), isFalse);
      expect(s.isAdminOf('a3'), isFalse);
      expect(s.isAdminOf('missing'), isFalse);
    });

    test('survives the server listing and the disk round trip', () {
      final parsed = AlbumModel.fromJson({
        'id': 'a1',
        'name_ct': null,
        'role': 'admin',
      });
      expect(parsed.myRole, 'admin');
      expect(AlbumModel.fromJson(parsed.toJson()).myRole, 'admin');
      expect(parsed.copyWith(mediaCount: 3).myRole, 'admin');
    });
  });

  group('rotation status', () {
    test('is held until the scheduler reports it clear', () {
      final s = AppState()..setAlbums([_album('a1')]);
      s.setRotationStatus('a1', _status(RotationPhase.waiting));
      expect(s.rotationFor('a1')?.phase, RotationPhase.waiting);

      s.setRotationStatus('a1', _status(RotationPhase.clear));
      expect(s.rotationFor('a1'), isNull);
    });

    test('a late report cannot resurrect a removed album', () {
      final s = AppState()..setAlbums([_album('a1')]);
      s.removeAlbum('a1');
      s.setRotationStatus('a1', _status(RotationPhase.failed));
      expect(s.rotationFor('a1'), isNull);
    });

    test('is dropped with the album and on reset', () {
      final s = AppState()..setAlbums([_album('a1'), _album('a2')]);
      s.setRotationStatus('a1', _status(RotationPhase.waiting));
      s.setRotationStatus('a2', _status(RotationPhase.waiting));

      s.removeAlbum('a1');
      expect(s.rotationFor('a1'), isNull);
      expect(s.rotationFor('a2'), isNotNull);

      s.reset();
      expect(s.rotationFor('a2'), isNull);
    });
  });

  group('rotation_required summary', () {
    AlbumModel flagged(String id, {String? role}) =>
        _album(id, role: role).copyWith(rotationRequired: true);

    test('survives the server listing and the disk round trip', () {
      final parsed = AlbumModel.fromJson({
        'id': 'a1',
        'name_ct': null,
        'rotation_required': true,
      });
      expect(parsed.rotationRequired, isTrue);
      expect(AlbumModel.fromJson(parsed.toJson()).rotationRequired, isTrue);
      expect(AlbumModel.fromJson({'id': 'a2'}).rotationRequired, isFalse);
    });

    test('shows a member the wait before any check runs', () {
      final s = AppState()..setAlbums([flagged('a1', role: 'member')]);
      expect(s.rotationFor('a1')?.phase, RotationPhase.waiting);
    });

    test('shows the admin an unsent key they can retry', () {
      final s = AppState()..setAlbums([flagged('a1', role: 'admin')]);
      final r = s.rotationFor('a1')!;
      expect(r.phase, RotationPhase.failed);
      expect(r.failure, RotationFailure.unavailable);
    });

    test('a live status wins over the summary', () {
      final s = AppState()..setAlbums([flagged('a1', role: 'admin')]);
      s.setRotationStatus('a1', _status(RotationPhase.rotating));
      expect(s.rotationFor('a1')?.phase, RotationPhase.rotating);
    });

    test('a cleared rotation drops the flag from the persisted shelf',
        () async {
      final persisted = <List<AlbumModel>>[];
      final s = AppState()
        ..attachShelfPersistence((albums) async => persisted.add(albums))
        ..setAlbums([flagged('a1')]);
      s.setRotationStatus('a1', _status(RotationPhase.waiting));

      s.setRotationStatus('a1', _status(RotationPhase.clear));
      await Future<void>.delayed(Duration.zero);

      expect(s.rotationFor('a1'), isNull);
      expect(persisted.last.single.rotationRequired, isFalse);
    });

    test('a status learned live marks the persisted shelf', () async {
      final persisted = <List<AlbumModel>>[];
      final s = AppState()
        ..attachShelfPersistence((albums) async => persisted.add(albums))
        ..setAlbums([_album('a1')]);

      s.setRotationStatus('a1', _status(RotationPhase.waiting));
      await Future<void>.delayed(Duration.zero);

      expect(persisted.last.single.rotationRequired, isTrue);
    });

    test('a flagged listing prompts recovery for albums not yet tracked', () {
      final prompted = <String>[];
      final s = AppState()..attachRotationPrompt(prompted.add);
      s.setAlbums([flagged('a1'), _album('a2'), flagged('a3')]);
      expect(prompted, ['a1', 'a3']);

      s.setRotationStatus('a1', _status(RotationPhase.waiting));
      prompted.clear();
      s.setAlbums([flagged('a1'), _album('a2'), flagged('a3')]);
      expect(prompted, ['a3'], reason: 'a1 is already being tracked');
    });
  });
}
