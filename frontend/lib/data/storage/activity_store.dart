import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/domain/activity/activity_event.dart';
import 'package:keepsy/e2ee/media_record.dart';

// Seal social-graph payloads and hash row keys so album ids remain hidden
// Only ordering and read state stay clear

const String _activityAad = 'keepsy.activity-v1';

abstract class ActivityFeed {
  Future<List<StoredActivity>> read({ActivityLane? lane});
  Future<void> markSeen(Iterable<String> ids);
  Future<int> unseenCount(ActivityLane lane);
  Future<void> dismiss(String id);
  Future<void> resolveVerified(SafetyNumberChanged e);
}

class StoredActivity {
  final ActivityEvent event;
  final bool seen;
  final bool dismissed;
  const StoredActivity({
    required this.event,
    required this.seen,
    this.dismissed = false,
  });
}

class ActivityStore implements ActivityFeed {
  final Database _db;
  final Uint8List _key;

  ActivityStore._(this._db, this._key);

  static Future<ActivityStore> open({
    required Uint8List cacheRootKey,
    Directory? dir,
  }) async {
    final root = dir ??
        Directory(p.join(
            (await getApplicationSupportDirectory()).path, 'keepsy_vault'));
    if (!root.existsSync()) root.createSync(recursive: true);
    final db = await openDatabase(
      p.join(root.path, 'activity.db'),
      version: 2,
      onUpgrade: (db, from, _) async {
        if (from < 2) {
          await db.execute(
              'ALTER TABLE activity ADD COLUMN dismissed INTEGER NOT NULL DEFAULT 0');
        }
      },
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE activity (
            row_key TEXT PRIMARY KEY,
            lane    INTEGER NOT NULL,
            at      INTEGER NOT NULL,
            seen    INTEGER NOT NULL DEFAULT 0,
            dismissed INTEGER NOT NULL DEFAULT 0,
            payload BLOB NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_activity_at ON activity(at DESC)');
        await db.execute(
            'CREATE TABLE snapshot (id INTEGER PRIMARY KEY, payload BLOB NOT NULL)');
      },
    );
    return ActivityStore._(db, cacheRootKey);
  }

  Future<void> close() => _db.close();

  // Social-graph history must not outlive its account
  Future<void> clearAll() async {
    await _db.delete('activity');
    await _db.delete('snapshot');
  }

  // Re-recording a known event must not resurrect it as unread, because
  // derivation re-emits the same transition on every launch
  Future<void> record(Iterable<ActivityEvent> events) async {
    final batch = _db.batch();
    await _insertAll(batch, events);
    await batch.commit(noResult: true);
  }

  // The events of one observation and the snapshot it produced, in one
  // transaction, so a crash can never keep one without the other
  Future<void> commit(
    List<ActivityEvent> events,
    Map<String, dynamic> snapshot, {
    List<String> settleAlbums = const [],
  }) async {
    final sealed = await _sealSnapshot(snapshot);
    final settled = <(String, Uint8List)>[];
    if (settleAlbums.isNotEmpty) {
      for (final r in await read(lane: ActivityLane.security)) {
        final e = r.event;
        if (e is MemberLeft &&
            e.rotationPending &&
            settleAlbums.contains(e.albumId)) {
          settled.add((await _rowKey(e.id), await _seal(e.settled())));
        }
      }
    }
    final batch = _db.batch();
    await _insertAll(batch, events);
    for (final (key, payload) in settled) {
      batch.update('activity', {'payload': payload},
          where: 'row_key = ?', whereArgs: [key]);
    }
    batch.insert('snapshot', {'id': 0, 'payload': sealed},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await batch.commit(noResult: true);
  }

  Future<void> _insertAll(Batch batch, Iterable<ActivityEvent> events) async {
    for (final e in events) {
      batch.insert(
        'activity',
        {
          'row_key': await _rowKey(e.id),
          'lane': e.lane.index,
          'at': e.at.millisecondsSinceEpoch,
          'seen': 0,
          'payload': await _seal(e),
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  @override
  Future<List<StoredActivity>> read({ActivityLane? lane}) async {
    final rows = await _db.query(
      'activity',
      where: lane == null ? null : 'lane = ?',
      whereArgs: lane == null ? null : [lane.index],
      orderBy: 'at DESC',
    );
    final out = <StoredActivity>[];
    for (final r in rows) {
      final event = await _open(r['payload'] as Uint8List);
      // A row that will not decrypt is a row we cannot show honestly
      if (event == null) continue;
      out.add(StoredActivity(
        event: event,
        seen: (r['seen'] as int) == 1,
        dismissed: (r['dismissed'] as int) == 1,
      ));
    }
    return out;
  }

  // Recompute the shelf dot so duplicates and restarts cannot desync it
  Future<bool> hasUnseen() async => (await read()).any((r) => !r.seen);

  @override
  Future<int> unseenCount(ActivityLane lane) async =>
      (await read(lane: lane)).where((r) => !r.seen).length;

  @override
  Future<void> markSeen(Iterable<String> ids) async {
    final batch = _db.batch();
    for (final id in ids) {
      batch.update('activity', {'seen': 1},
          where: 'row_key = ?', whereArgs: [await _rowKey(id)]);
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<void> dismiss(String id) async {
    await _db.update('activity', {'dismissed': 1, 'seen': 1},
        where: 'row_key = ?', whereArgs: [await _rowKey(id)]);
  }

  Future<void> replace(ActivityEvent e) async {
    await _db.update('activity', {'payload': await _seal(e)},
        where: 'row_key = ?', whereArgs: [await _rowKey(e.id)]);
  }

  Future<void> settleRotation(String albumId) async {
    for (final r in await read(lane: ActivityLane.security)) {
      final e = r.event;
      if (e is MemberLeft && e.albumId == albumId && e.rotationPending) {
        await replace(e.settled());
      }
    }
  }

  // Update payload and flags atomically so a crash cannot resurrect the card
  @override
  Future<void> resolveVerified(SafetyNumberChanged e) async {
    final payload = await _seal(e.asVerified());
    await _db.update(
      'activity',
      {'payload': payload, 'dismissed': 1, 'seen': 1},
      where: 'row_key = ?',
      whereArgs: [await _rowKey(e.id)],
    );
  }

  // Album rows age out; security rows remain as the access record
  Future<void> prune({required DateTime albumRowsBefore}) async {
    await _db.delete(
      'activity',
      where: 'lane = ? AND at < ?',
      whereArgs: [
        ActivityLane.albums.index,
        albumRowsBefore.millisecondsSinceEpoch,
      ],
    );
  }

  Future<Map<String, dynamic>?> readSnapshot() async {
    final rows = await _db.query('snapshot', where: 'id = 0');
    if (rows.isEmpty) return null;
    try {
      final clear = await Aead.decrypt(
        wire: rows.first['payload'] as Uint8List,
        key: _key,
        aad: Uint8List.fromList(utf8.encode(_activityAad)),
      );
      return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    } catch (_) {
      // Unreadable is the same as absent: the next pass re-seeds the baseline
      return null;
    }
  }

  Future<Uint8List> _sealSnapshot(Map<String, dynamic> snapshot) =>
      Aead.encrypt(
        version: kVerAesGcm,
        key: _key,
        plaintext: Uint8List.fromList(utf8.encode(jsonEncode(snapshot))),
        aad: Uint8List.fromList(utf8.encode(_activityAad)),
      );

  // An account with no published identity cannot belong to any album, so its
  // empty shelf is a real baseline and its first album must be news
  Future<void> seedEmptyBaseline() async {
    final rows = await _db.query('snapshot', where: 'id = 0');
    if (rows.isNotEmpty) return;
    await writeSnapshot(const {});
  }

  Future<void> writeSnapshot(Map<String, dynamic> snapshot) async {
    final sealed = await _sealSnapshot(snapshot);
    await _db.insert(
      'snapshot',
      {'id': 0, 'payload': sealed},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // Hashed so the primary key cannot leak the album id its stable id contains
  static Future<String> _rowKey(String id) async {
    final h = await cg.Sha256().hash(utf8.encode('$_activityAad:$id'));
    return base64Url.encode(h.bytes);
  }

  Future<Uint8List> _seal(ActivityEvent e) => Aead.encrypt(
        version: kVerAesGcm,
        key: _key,
        plaintext: Uint8List.fromList(utf8.encode(jsonEncode(_toJson(e)))),
        aad: Uint8List.fromList(utf8.encode(_activityAad)),
      );

  Future<ActivityEvent?> _open(Uint8List wire) async {
    try {
      final clear = await Aead.decrypt(
        wire: wire,
        key: _key,
        aad: Uint8List.fromList(utf8.encode(_activityAad)),
      );
      return _fromJson(jsonDecode(utf8.decode(clear)) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

Map<String, dynamic> _toJson(ActivityEvent e) => {
      'id': e.id,
      'album_id': e.albumId,
      'at': e.at.millisecondsSinceEpoch,
      ...switch (e) {
        PhotosAdded() => {
            'kind': 'added',
            'count': e.count,
            if (e.uploaderToken != null) 'uploader': e.uploaderToken,
            if (e.previews.isNotEmpty)
              'previews': [for (final r in e.previews) r.toJson()],
          },
        MemberJoined() => {'kind': 'joined', 'member': e.memberToken},
        MemberLeft() => {
            'kind': 'left',
            'member': e.memberToken,
            if (e.rotationPending) 'rotation_pending': true,
          },
        SafetyNumberChanged() => {
            'kind': 'trust',
            'peer': e.peerToken,
            if (e.presentedIk != null) 'ik': base64.encode(e.presentedIk!),
            if (e.verified) 'verified': true,
          },
        InvitedToAlbum() => {'kind': 'invited'},
        RemovedFromAlbum() => {'kind': 'removed'},
      },
    };

ActivityEvent? _fromJson(Map<String, dynamic> j) {
  final id = j['id'] as String;
  final albumId = j['album_id'] as String;
  final at = DateTime.fromMillisecondsSinceEpoch(j['at'] as int, isUtc: true);
  return switch (j['kind'] as String) {
    'added' => PhotosAdded(
        id: id,
        albumId: albumId,
        at: at,
        count: j['count'] as int,
        uploaderToken: j['uploader'] as String?,
        previews: _previews(j['previews']),
      ),
    'joined' => MemberJoined(
        id: id, albumId: albumId, at: at, memberToken: j['member'] as String),
    'left' => MemberLeft(
        id: id,
        albumId: albumId,
        at: at,
        memberToken: j['member'] as String,
        rotationPending: j['rotation_pending'] == true,
      ),
    'trust' => SafetyNumberChanged(
        id: id,
        albumId: albumId,
        at: at,
        peerToken: j['peer'] as String,
        presentedIk: j['ik'] == null ? null : base64.decode(j['ik'] as String),
        verified: j['verified'] == true,
      ),
    'invited' => InvitedToAlbum(id: id, albumId: albumId, at: at),
    'removed' => RemovedFromAlbum(id: id, albumId: albumId, at: at),
    _ => null,
  };
}

// Drop an unreadable preview without discarding its activity row
List<MediaRecord> _previews(Object? raw) {
  if (raw is! List) return const [];
  final out = <MediaRecord>[];
  for (final r in raw) {
    try {
      out.add(MediaRecord.fromJson(r as Map<String, dynamic>));
    } catch (_) {}
  }
  return out;
}
