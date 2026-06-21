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

// L2 disk cache : each blob is sealed under cache_root_key as the Aead wire
// VER‖NONCE‖TAG‖CT, NOT the S3 ciphertext. readBlob/writeBlob deal in
// plaintext, seal/unseal is internal. A filesystem dump yields opaque blobs
// AAD = media_id‖asset binds a file to its slot so a swapped blob auth-fails
// records.db doubles as the LRU access time index (size = sealed footprint)

const String _formatSentinel = 'format_v2';

class MediaSealedCache {
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
    // Row may not exist yet (writeBlob without a prior writeRecord, eg a
    // prefetch race) : insert a placeholder so the size isnt lost
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
        col: sealed.length,
        'last_access': now,
      });
    } else {
      await _db.update(
          'media_records', {col: sealed.length, 'last_access': now},
          where: 'media_id = ?', whereArgs: [k.mediaId]);
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
      final freed = (row['blob_bytes'] as int) + (row['thumb_bytes'] as int);
      await invalidate(row['media_id'] as String);
      total -= freed;
    }
  }

  Future<void> invalidate(String mediaId) async {
    await _db
        .delete('media_records', where: 'media_id = ?', whereArgs: [mediaId]);
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
  }

  Future<void> clearAll() async {
    await _db.delete('media_records');
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
