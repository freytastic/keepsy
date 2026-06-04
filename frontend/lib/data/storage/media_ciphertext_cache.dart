import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'package:keepsy/e2ee/media_record.dart';

import 'media_cache_key.dart';

// L2 disk cache : raw ciphertext blobs byte identical to what S3 holds, plus
// a sqlite index (records.db) so MediaRecord fields (wrap_nonce/wrap_tag_ct/
// epoch_tag) survive a restart. Decryption never happens here : that's L1
// territory via FileDecryptor. Eviction LRU by last_access, default 500 MB

class MediaCiphertextCache {
  final Directory _root;
  final Database _db;
  final int budgetBytes;

  MediaCiphertextCache._(this._root, this._db, this.budgetBytes);

  static Future<MediaCiphertextCache> open({
    Directory? rootDir,
    int budgetBytes = 500 * 1024 * 1024,
  }) async {
    final root = rootDir ??
        Directory(p.join(
            (await getApplicationCacheDirectory()).path, 'keepsy_media'));
    if (!root.existsSync()) root.createSync(recursive: true);
    final dbPath = p.join(root.path, 'records.db');
    final db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE media_records (
            media_id    TEXT PRIMARY KEY,
            album_id    TEXT NOT NULL,
            record_json TEXT NOT NULL,
            blob_bytes  INTEGER NOT NULL DEFAULT 0,
            thumb_bytes INTEGER NOT NULL DEFAULT 0,
            last_access INTEGER NOT NULL
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_records_album ON media_records(album_id)');
        await db.execute(
            'CREATE INDEX idx_records_access ON media_records(last_access)');
      },
    );
    return MediaCiphertextCache._(root, db, budgetBytes);
  }

  Future<void> close() => _db.close();

  Future<MediaRecord?> readRecord(String mediaId) async {
    final rows = await _db.query('media_records',
        columns: ['record_json'],
        where: 'media_id = ?',
        whereArgs: [mediaId],
        limit: 1);
    if (rows.isEmpty) return null;
    final j =
        jsonDecode(rows.first['record_json'] as String) as Map<String, dynamic>;
    return MediaRecord.fromJson(j);
  }

  Future<void> writeRecord(MediaRecord r) async {
    await _db.insert(
      'media_records',
      {
        'media_id': r.id,
        'album_id': r.albumId,
        'record_json': jsonEncode(r.toJson()),
        'last_access': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  File _blobFile(MediaCacheKey k) => File(p.join(_root.path, k.diskFilename));

  Future<Uint8List?> readBlob(MediaCacheKey k) async {
    final f = _blobFile(k);
    if (!f.existsSync()) return null;
    try {
      final b = await f.readAsBytes();
      await _db.update('media_records',
          {'last_access': DateTime.now().millisecondsSinceEpoch},
          where: 'media_id = ?', whereArgs: [k.mediaId]);
      return b;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeBlob(MediaCacheKey k, Uint8List ciphertext) async {
    final f = _blobFile(k);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(ciphertext, flush: true);
    await tmp.rename(f.path);
    final col = k.asset == CacheAsset.thumb ? 'thumb_bytes' : 'blob_bytes';
    // Make sure the row exists before we update : a writeBlob without a
    // prior writeRecord (eg prefetch race) would silently no-op otherwise
    final exists = await _db.query('media_records',
        columns: ['media_id'],
        where: 'media_id = ?',
        whereArgs: [k.mediaId],
        limit: 1);
    if (exists.isEmpty) {
      await _db.insert('media_records', {
        'media_id': k.mediaId,
        'album_id': k.albumId,
        'record_json': '{}',
        col: ciphertext.length,
        'last_access': DateTime.now().millisecondsSinceEpoch,
      });
    } else {
      await _db.update(
        'media_records',
        {
          col: ciphertext.length,
          'last_access': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'media_id = ?',
        whereArgs: [k.mediaId],
      );
    }
    await _evictIfOverBudget();
  }

  Future<void> _evictIfOverBudget() async {
    var total = await totalBytes();
    if (total <= budgetBytes) return;
    final rows = await _db.query('media_records',
        columns: ['media_id', 'blob_bytes', 'thumb_bytes'],
        orderBy: 'last_access ASC');
    for (final row in rows) {
      if (total <= budgetBytes) break;
      final id = row['media_id'] as String;
      final freed = (row['blob_bytes'] as int) + (row['thumb_bytes'] as int);
      await invalidate(id);
      total -= freed;
    }
  }

  Future<void> invalidate(String mediaId) async {
    await _db
        .delete('media_records', where: 'media_id = ?', whereArgs: [mediaId]);
    for (final asset in CacheAsset.values) {
      final f = File(p.join(_root.path,
          asset == CacheAsset.thumb ? '$mediaId.thumb.bin' : '$mediaId.bin'));
      if (f.existsSync()) f.deleteSync();
    }
  }

  Future<void> clearAlbum(String albumId) async {
    final rows = await _db.query('media_records',
        columns: ['media_id'], where: 'album_id = ?', whereArgs: [albumId]);
    for (final r in rows) {
      await invalidate(r['media_id'] as String);
    }
  }

  Future<void> clearAll() async {
    await _db.delete('media_records');
    for (final e in _root.listSync()) {
      if (e is File && e.path.endsWith('.bin')) e.deleteSync();
    }
  }

  Future<int> totalBytes() async {
    final rows = await _db.rawQuery(
        'SELECT COALESCE(SUM(blob_bytes), 0) + COALESCE(SUM(thumb_bytes), 0) AS t FROM media_records');
    return (rows.first['t'] as int);
  }
}
