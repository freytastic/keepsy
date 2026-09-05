import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/e2ee/media_record.dart';

import 'media_cache_key.dart';
import 'media_catalog.dart';

// L2 disk cache : each blob is sealed under cache_root_key as the Aead wire
// VER‖NONCE‖TAG‖CT, NOT the S3 ciphertext. readBlob/writeBlob deal in
// plaintext, seal/unseal is internal. A filesystem dump yields opaque blobs
// AAD = media_id‖asset binds a file to its slot so a swapped blob auth-fails
// records.db doubles as the LRU access time index (size = sealed footprint)

const String _formatSentinel = 'format_v2';

// Pins visible shelf thumbnails during eviction
const String _createCovers = '''
  CREATE TABLE album_covers (
    album_id TEXT NOT NULL,
    media_id TEXT NOT NULL,
    slot     INTEGER NOT NULL,
    PRIMARY KEY (album_id, slot)
  )
''';

class MediaSealedCache implements MediaCatalog {
  final Directory _root;
  final Database _db;
  final Uint8List _cacheKey;
  final int budgetBytes;

  MediaSealedCache._(this._root, this._db, this._cacheKey, this.budgetBytes);

  static Future<MediaSealedCache> open({
    Directory? rootDir,
    required Uint8List cacheRootKey,
    int budgetBytes = 1024 * 1024 * 1024,
  }) async {
    // getApplicationCacheDirectory : Android app cache dir (covered by
    // allowBackup="false" in the manifest) / iOS Library/Caches (excluded from
    // iCloud backup by OS default). Sealed blobs never reach cloud backup
    final root = rootDir ??
        Directory(p.join(
            (await getApplicationCacheDirectory()).path, 'keepsy_media'));
    if (!root.existsSync()) root.createSync(recursive: true);
    final db = await openDatabase(
      p.join(root.path, 'records.db'),
      version: 3,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE media_records (
            media_id    TEXT PRIMARY KEY,
            album_id    TEXT NOT NULL,
            record_json TEXT NOT NULL,
            blob_bytes  INTEGER NOT NULL DEFAULT 0,
            thumb_bytes INTEGER NOT NULL DEFAULT 0,
            last_access INTEGER NOT NULL,
            sort_index  INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_records_album ON media_records(album_id)');
        await db.execute(
            'CREATE INDEX idx_records_access ON media_records(last_access)');
        await db.execute(_createCovers);
      },
      onUpgrade: (db, from, to) async {
        if (from < 2) await db.execute(_createCovers);
        // created_at is only hour-precise, so persist explicit server order
        if (from < 3) {
          await db.execute('ALTER TABLE media_records '
              'ADD COLUMN sort_index INTEGER NOT NULL DEFAULT 0');
        }
      },
    );
    final cache = MediaSealedCache._(root, db, cacheRootKey, budgetBytes);
    await cache._migrateIfNeeded();
    return cache;
  }

  Future<void> close() => _db.close();

  // First boot on the sealed format : wipe any prior-layout blobs + index
  // rows (D9′ : zero prod users, no dual format read path). Also self heals a
  // wholesale key mismatch (sentinel lost) by starting clean
  Future<void> _migrateIfNeeded() async {
    final sentinel = File(p.join(_root.path, _formatSentinel));
    if (sentinel.existsSync()) return;
    await _db.delete('media_records');
    await _db.delete('album_covers');
    for (final e in _root.listSync()) {
      if (e is File && _isBlobFile(e.path)) e.deleteSync();
    }
    sentinel.writeAsStringSync('2');
  }

  static bool _isBlobFile(String path) =>
      path.endsWith('.kec') || path.endsWith('.bin') || path.endsWith('.tmp');

  Uint8List _aad(MediaCacheKey k) => Uint8List.fromList(
        utf8.encode(k.mediaId) +
            utf8.encode(k.asset == CacheAsset.thumb ? 'thumb' : 'file'),
      );

  File _blobFile(MediaCacheKey k) => File(p.join(_root.path, k.diskFilename));

  Future<MediaRecord?> readRecord(String mediaId) async {
    final rows = await _db.query('media_records',
        columns: ['record_json'],
        where: 'media_id = ?',
        whereArgs: [mediaId],
        limit: 1);
    if (rows.isEmpty) return null;
    // A bytes only placeholder is not a complete record
    final raw = rows.first['record_json'] as String;
    if (raw.length <= 2) return null;
    try {
      return MediaRecord.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  // Ignore byte-accounting placeholders without render metadata
  @override
  Future<List<MediaRecord>> listRecordsForAlbum(String albumId) async {
    final rows = await _db.query('media_records',
        columns: ['record_json'],
        where: 'album_id = ? AND length(record_json) > 2',
        whereArgs: [albumId],
        orderBy: 'sort_index ASC');
    final out = <MediaRecord>[];
    for (final row in rows) {
      try {
        out.add(MediaRecord.fromJson(
            jsonDecode(row['record_json'] as String) as Map<String, dynamic>));
      } catch (_) {
        // Keep one corrupt row from hiding the rest of the album
      }
    }
    return out;
  }

  @override
  Future<void> reconcileAlbum(String albumId, List<MediaRecord> records) async {
    final keep = {for (final r in records) r.id};
    final existing = await _db.query('media_records',
        columns: ['media_id'], where: 'album_id = ?', whereArgs: [albumId]);

    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      for (var i = 0; i < records.length; i++) {
        final r = records[i];
        final json = jsonEncode(r.toJson());
        await txn.rawInsert(
          'INSERT OR IGNORE INTO media_records '
          '(media_id, album_id, record_json, last_access, sort_index) '
          'VALUES (?, ?, ?, ?, ?)',
          [r.id, albumId, json, now, i],
        );
        // A listing is not a view, so it must not refresh the LRU timestamp
        await txn.rawUpdate(
          'UPDATE media_records SET album_id = ?, record_json = ?, '
          'sort_index = ? WHERE media_id = ?',
          [albumId, json, i, r.id],
        );
      }
    });

    for (final row in existing) {
      final id = row['media_id'] as String;
      if (!keep.contains(id)) await invalidate(id);
    }
  }

  // Preserve byte accounting without REPLACE or API 30 only UPSERT syntax
  Future<void> writeRecord(MediaRecord r) async {
    final json = jsonEncode(r.toJson());
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      // New arrivals stay first until the next server reconciliation
      await txn.rawInsert(
        'INSERT OR IGNORE INTO media_records '
        '(media_id, album_id, record_json, last_access, sort_index) '
        'VALUES (?, ?, ?, ?, '
        'COALESCE((SELECT MIN(sort_index) - 1 FROM media_records '
        'WHERE album_id = ?), -1))',
        [r.id, r.albumId, json, now, r.albumId],
      );
      await txn.rawUpdate(
        'UPDATE media_records SET album_id = ?, record_json = ?, '
        'last_access = ? WHERE media_id = ?',
        [r.albumId, json, now, r.id],
      );
    });
  }

  // Preview records may fill placeholders but never overwrite full records
  Future<void> writeRecordIfAbsent(MediaRecord r) async {
    final json = jsonEncode(r.toJson());
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      // Put new previews first, including when filling a placeholder row
      await txn.rawInsert(
        'INSERT OR IGNORE INTO media_records '
        '(media_id, album_id, record_json, last_access, sort_index) '
        'VALUES (?, ?, ?, ?, '
        'COALESCE((SELECT MIN(sort_index) - 1 FROM media_records '
        'WHERE album_id = ?), -1))',
        [r.id, r.albumId, json, now, r.albumId],
      );
      await txn.rawUpdate(
        "UPDATE media_records SET record_json = ?, last_access = ?, "
        "sort_index = COALESCE("
        "(SELECT MIN(sort_index) - 1 FROM media_records WHERE album_id = ?), -1) "
        "WHERE media_id = ? AND record_json = '{}'",
        [json, now, r.albumId, r.id],
      );
    });
  }

  Future<Uint8List?> readBlob(MediaCacheKey k) async {
    final f = _blobFile(k);
    if (!f.existsSync()) return null;
    Uint8List wire;
    try {
      wire = await f.readAsBytes();
    } catch (_) {
      return null;
    }
    try {
      final pt = await Aead.decrypt(wire: wire, key: _cacheKey, aad: _aad(k));
      await _db.update('media_records',
          {'last_access': DateTime.now().millisecondsSinceEpoch},
          where: 'media_id = ?', whereArgs: [k.mediaId]);
      return pt;
    } on AeadAuthFailed {
      // D12′ : tampered or wrong key (eg cache_root_key changed) → purge + miss
      await invalidate(k.mediaId);
      return null;
    } on FormatException {
      await invalidate(k.mediaId);
      return null;
    }
  }

  Future<void> writeBlob(MediaCacheKey k, Uint8List plaintext) async {
    final sealed = await Aead.encrypt(
        version: kVerAesGcm,
        key: _cacheKey,
        plaintext: plaintext,
        aad: _aad(k));
    final f = _blobFile(k);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(sealed, flush: true);
    await tmp.rename(f.path);
    final col = k.asset == CacheAsset.thumb ? 'thumb_bytes' : 'blob_bytes';
    final now = DateTime.now().millisecondsSinceEpoch;
    // Atomically create the row and update its asset size
    await _db.transaction((txn) async {
      await txn.rawInsert(
        'INSERT OR IGNORE INTO media_records '
        "(media_id, album_id, record_json, last_access) VALUES (?, ?, '{}', ?)",
        [k.mediaId, k.albumId, now],
      );
      await txn.rawUpdate(
        'UPDATE media_records SET $col = ?, last_access = ? WHERE media_id = ?',
        [sealed.length, now, k.mediaId],
      );
    });
    await _evictIfOverBudget();
  }

  // Evict assets separately so pinned thumbnails do not pin full files
  Future<void> _evictIfOverBudget() async {
    var total = await totalBytes();
    if (total <= budgetBytes) return;
    final pinned = await _pinnedMediaIds();
    final rows = await _db.query('media_records',
        columns: ['media_id', 'blob_bytes', 'thumb_bytes'],
        orderBy: 'last_access ASC');

    for (final row in rows) {
      if (total <= budgetBytes) break;
      final bytes = row['blob_bytes'] as int;
      if (bytes == 0) continue;
      await _dropAsset(row['media_id'] as String, CacheAsset.file);
      total -= bytes;
    }
    for (final row in rows) {
      if (total <= budgetBytes) break;
      final id = row['media_id'] as String;
      if (pinned.contains(id)) continue;
      final bytes = row['thumb_bytes'] as int;
      if (bytes == 0) continue;
      await _dropAsset(id, CacheAsset.thumb);
      total -= bytes;
    }
    // Keep metadata-only rows so albums remain available offline
    await _db.delete('media_records',
        where:
            'blob_bytes = 0 AND thumb_bytes = 0 AND length(record_json) <= 2');
  }

  Future<Set<String>> _pinnedMediaIds() async {
    final rows = await _db.query('album_covers', columns: ['media_id']);
    return {for (final r in rows) r['media_id'] as String};
  }

  Future<void> _dropAsset(String mediaId, CacheAsset asset) async {
    final name =
        asset == CacheAsset.thumb ? '$mediaId.thumb.kec' : '$mediaId.kec';
    final f = File(p.join(_root.path, name));
    if (f.existsSync()) f.deleteSync();
    final col = asset == CacheAsset.thumb ? 'thumb_bytes' : 'blob_bytes';
    await _db.update('media_records', {col: 0},
        where: 'media_id = ?', whereArgs: [mediaId]);
  }

  // Replace a cover registry atomically to prevent stale interleaving
  Future<void> setCovers(String albumId, List<String> mediaIds) async {
    await _db.transaction((txn) async {
      await txn
          .delete('album_covers', where: 'album_id = ?', whereArgs: [albumId]);
      for (var i = 0; i < mediaIds.length && i < 3; i++) {
        await txn.insert(
            'album_covers',
            {
              'album_id': albumId,
              'media_id': mediaIds[i],
              'slot': i,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<List<String>> coversFor(String albumId) async {
    final rows = await _db.query('album_covers',
        columns: ['media_id'],
        where: 'album_id = ?',
        whereArgs: [albumId],
        orderBy: 'slot ASC');
    return [for (final r in rows) r['media_id'] as String];
  }

  Future<void> invalidate(String mediaId) async {
    await _db
        .delete('media_records', where: 'media_id = ?', whereArgs: [mediaId]);
    await _db
        .delete('album_covers', where: 'media_id = ?', whereArgs: [mediaId]);
    for (final asset in CacheAsset.values) {
      final name =
          asset == CacheAsset.thumb ? '$mediaId.thumb.kec' : '$mediaId.kec';
      final f = File(p.join(_root.path, name));
      if (f.existsSync()) f.deleteSync();
    }
  }

  Future<void> clearAlbum(String albumId) async {
    final rows = await _db.query('media_records',
        columns: ['media_id'], where: 'album_id = ?', whereArgs: [albumId]);
    for (final r in rows) {
      await invalidate(r['media_id'] as String);
    }
    await _db
        .delete('album_covers', where: 'album_id = ?', whereArgs: [albumId]);
  }

  Future<void> clearAll() async {
    await _db.delete('media_records');
    await _db.delete('album_covers');
    for (final e in _root.listSync()) {
      if (e is File && e.path.endsWith('.kec')) e.deleteSync();
    }
  }

  Future<int> totalBytes() async {
    final rows = await _db.rawQuery(
        'SELECT COALESCE(SUM(blob_bytes), 0) + COALESCE(SUM(thumb_bytes), 0) AS t FROM media_records');
    return (rows.first['t'] as int);
  }
}
