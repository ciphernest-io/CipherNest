import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../src/models/file_model.dart';
import '../src/models/album_model.dart';
import '../src/models/share_model.dart';
import 'cache_manager_service.dart';
import 'cloud/account_registry.dart';
import 'cloud/sealed_metadata.dart';

/// [DatabaseService] extends [ChangeNotifier] so screens can rebuild in-place
/// when files are added, deleted, restored, or moved between albums. Every
/// mutating write ends with [notifyListeners]; every list-rendering screen
/// subscribes with [addListener] in initState and unsubscribes in dispose.
/// This kills the pull-to-refresh requirement after a delete.
class DatabaseService extends ChangeNotifier {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  Database? _database;
  String? _currentAccountId;

  void setCurrentAccount(String email) {
    _currentAccountId = email;
    notifyListeners();
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  Future<String> getDatabasePath() async {
    final dbPath = await getDatabasesPath();
    return join(dbPath, 'ciphernest_v3.db');
  }

  Future<void> closeDatabase() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'ciphernest_v3.db');

    final db = await openDatabase(
      path,
      version: 8,
      onCreate: (db, version) async {
        await _createSchema(db);
        await _seedSmartAlbums(db);
        await _seedSmartPlaylists(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // v2 added albums tables; v3 changes account_id semantics from
        // bare email to composite ${provider}_${email}. The data model
        // shift is incompatible with old rows, so we wipe everything and
        // let users re-link/sync from cloud.
        //
        // IMPORTANT: _createSchema produces the *current* (v7+) schema, so
        // after the wipe-and-recreate the DB is already at the latest version
        // — bail out before the additive ALTER TABLE migrations below try to
        // re-add columns that the recreate already included (which would
        // throw "duplicate column name").
        if (oldVersion < 3) {
          await db.execute('DROP TABLE IF EXISTS album_files');
          await db.execute('DROP TABLE IF EXISTS albums');
          await db.execute('DROP TABLE IF EXISTS files');
          await _createSchema(db);
          await _seedSmartAlbums(db);
          return;
        }
        // v4 adds the `shares` table for outbound share tracking.
        if (oldVersion < 4) {
          await db.execute(_createSharesTableSql);
        }
        // v5 adds the photo_manager AssetEntity id so the grid can fetch the
        // same thumbnail Android's MediaStore serves Samsung Gallery.
        if (oldVersion < 5) {
          await db.execute('ALTER TABLE files ADD COLUMN asset_id TEXT');
        }
        // v6 adds the favorites flag.
        if (oldVersion < 6) {
          await db.execute(
            'ALTER TABLE files ADD COLUMN is_favorite INTEGER DEFAULT 0',
          );
        }
        // v7 adds soft-delete columns for the Recycle Bin. Rows with
        // is_deleted = 1 are hidden from every list query and only surface
        // in the Recycle Bin screen until they expire (default 30 days).
        if (oldVersion < 7) {
          await db.execute(
            'ALTER TABLE files ADD COLUMN is_deleted INTEGER DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE files ADD COLUMN deleted_at INTEGER',
          );
        }
        // v8 splits albums by kind: 'photo' (gallery albums) vs 'audio'
        // (music playlists). Both live in the same tables — album_files is
        // file-type agnostic — the kind column just keeps the two UIs from
        // seeing each other's collections.
        if (oldVersion < 8) {
          await db.execute(
            "ALTER TABLE albums ADD COLUMN kind TEXT NOT NULL DEFAULT 'photo'",
          );
          await _seedSmartPlaylists(db);
        }
      },
    );
    await db.execute('PRAGMA foreign_keys = ON');
    return db;
  }

  static const String _createSharesTableSql = '''
      CREATE TABLE shares(
        id TEXT PRIMARY KEY,
        file_id TEXT NOT NULL,
        cloud_id TEXT NOT NULL,
        download_url TEXT NOT NULL,
        share_url TEXT NOT NULL,
        has_password INTEGER NOT NULL,
        expires_at INTEGER,
        created_at INTEGER NOT NULL,
        account_id TEXT NOT NULL,
        FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
      )
    ''';

  static Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE files(
        id TEXT PRIMARY KEY,
        cloud_id TEXT,
        thumbnail_cloud_id TEXT,
        provider INTEGER DEFAULT 0,
        account_id TEXT,
        filename TEXT NOT NULL,
        size_bytes INTEGER,
        created_at INTEGER,
        is_uploaded INTEGER,
        local_path TEXT,
        asset_id TEXT,
        is_favorite INTEGER DEFAULT 0,
        is_deleted INTEGER DEFAULT 0,
        deleted_at INTEGER,
        type INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE albums(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        cover_file_id TEXT,
        is_smart INTEGER DEFAULT 0,
        smart_query TEXT,
        kind TEXT NOT NULL DEFAULT 'photo',
        created_at INTEGER,
        updated_at INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE album_files(
        album_id TEXT NOT NULL,
        file_id TEXT NOT NULL,
        added_at INTEGER,
        PRIMARY KEY (album_id, file_id),
        FOREIGN KEY (album_id) REFERENCES albums(id) ON DELETE CASCADE,
        FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(_createSharesTableSql);
  }

  static Future<void> _seedSmartAlbums(Database db) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final album in [
      {'id': 'smart_all_photos', 'name': 'All Photos', 'query': 'all_images'},
      {'id': 'smart_camera', 'name': 'Camera', 'query': 'camera'},
      {'id': 'smart_screenshots', 'name': 'Screenshots', 'query': 'screenshots'},
      {'id': 'smart_videos', 'name': 'Videos', 'query': 'videos'},
    ]) {
      await db.insert('albums', {
        'id': album['id'],
        'name': album['name'],
        'is_smart': 1,
        'smart_query': album['query'],
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  static Future<void> _seedSmartPlaylists(Database db) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final playlist in [
      {
        'id': 'smart_audio_recent',
        'name': 'Recently added',
        'query': 'audio_recent',
      },
      {
        'id': 'smart_audio_favourites',
        'name': 'Favourites',
        'query': 'audio_favourites',
      },
    ]) {
      await db.insert('albums', {
        'id': playlist['id'],
        'name': playlist['name'],
        'is_smart': 1,
        'smart_query': playlist['query'],
        'kind': 'audio',
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  // --- CRUD Operations ---

  Future<void> addFile(CnestFile file) async {
    final db = await database;
    final fileWithAccount = CnestFile(
      id: file.id,
      filename: file.filename,
      sizeBytes: file.sizeBytes,
      createdAt: file.createdAt,
      type: file.type,
      localPath: file.localPath,
      isUploaded: file.isUploaded,
      cloudId: file.cloudId,
      thumbnailCloudId: file.thumbnailCloudId,
      provider: AccountRegistry().activeAccount?.providerType ?? 0,
      accountId: _currentAccountId,
    );

    await db.insert(
      'files',
      fileWithAccount.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    notifyListeners();
  }

  Future<void> markAsUploaded(String id, String cloudId, String? thumbId) async {
    final db = await database;
    await db.update(
      'files',
      {
        'is_uploaded': 1,
        'cloud_id': cloudId,
        'thumbnail_cloud_id': thumbId,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyListeners();
  }

  /// Patches the size of an existing row. Used after the in-app editor
  /// replaces the original — the file bytes change so the cached size
  /// must follow.
  Future<void> updateSizeBytes(String id, int sizeBytes) async {
    final db = await database;
    await db.update(
      'files',
      {'size_bytes': sizeBytes},
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyListeners();
  }

  /// Soft-delete: hides the row from every gallery query and stamps the
  /// deletion time so the Recycle Bin can show "X days left" and the sweep
  /// can purge it after the TTL. The encrypted cloud blob is left alone so
  /// restores are instant and offline.
  ///
  /// Additionally: wipes the decrypted-cache artifacts for this file so the
  /// grid stops rendering its thumbnail instantly, and bumps [notifyListeners]
  /// so every subscribed screen re-queries in place (no pull-to-refresh
  /// required).
  Future<void> deleteFile(String id) async {
    final db = await database;
    final rows = await db.query(
      'files',
      columns: ['cloud_id', 'thumbnail_cloud_id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    await db.update(
      'files',
      {
        'is_deleted': 1,
        'deleted_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isNotEmpty) {
      await CacheManagerService().invalidateFile(
        fileId: id,
        cloudId: rows.first['cloud_id'] as String?,
        thumbnailCloudId: rows.first['thumbnail_cloud_id'] as String?,
      );
    }
    notifyListeners();
  }

  /// Hard delete — used by the Recycle Bin "Delete forever" path and by the
  /// 30-day sweeper. Callers are responsible for the cloud blob and any
  /// cached artifacts; this only removes the SQLite row.
  Future<void> permanentlyDeleteFile(String id) async {
    final db = await database;
    await db.delete('files', where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  /// Soft-deleted rows for the current account, most-recently-trashed first.
  Future<List<CnestFile>> getDeletedFiles() async {
    final db = await database;
    if (_currentAccountId == null) return [];
    final maps = await db.query(
      'files',
      where: 'is_deleted = 1 AND account_id = ?',
      whereArgs: [_currentAccountId],
      orderBy: 'deleted_at DESC',
    );
    return maps.map((m) => CnestFile.fromMap(m)).toList();
  }

  /// Returns the millisecondsSinceEpoch a file was soft-deleted, or null if
  /// the row is missing / not deleted. The Recycle Bin uses this to render
  /// the "X days left" chip without bloating CnestFile with a transient
  /// field that's only meaningful for trashed rows.
  Future<int?> getDeletedAt(String id) async {
    final db = await database;
    final rows = await db.query(
      'files',
      columns: ['deleted_at'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['deleted_at'] as int?;
  }

  /// Undoes a soft-delete. Clears the deleted_at stamp so future sweeps
  /// don't grab it again.
  Future<void> restoreFile(String id) async {
    final db = await database;
    await db.update(
      'files',
      {'is_deleted': 0, 'deleted_at': null},
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyListeners();
  }

  /// Ids of soft-deleted rows whose [deleted_at] is older than [ttl]. Used
  /// by RecycleBinService to find rows that should be purged from cloud
  /// and the local DB. Scoped to the current account so users don't have
  /// to be on a specific account to clean up their own trash.
  Future<List<String>> getExpiredDeletionIds({
    Duration ttl = const Duration(days: 30),
  }) async {
    final db = await database;
    if (_currentAccountId == null) return [];
    final cutoff =
        DateTime.now().subtract(ttl).millisecondsSinceEpoch;
    final rows = await db.query(
      'files',
      columns: ['id'],
      where: 'is_deleted = 1 AND account_id = ? AND deleted_at IS NOT NULL '
          'AND deleted_at <= ?',
      whereArgs: [_currentAccountId, cutoff],
    );
    return rows.map((r) => r['id'] as String).toList();
  }

  Future<CnestFile?> getFileById(String id) async {
    final db = await database;
    final rows =
        await db.query('files', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : CnestFile.fromMap(rows.first);
  }

  Future<void> setFavorite(String id, bool favorite) async {
    final db = await database;
    await db.update(
      'files',
      {'is_favorite': favorite ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Updates the user-visible filename. The cloud blob keeps its `<uuid>.cnest`
  /// name; only the metadata-derived display name changes. After a full wipe
  /// and cloud-restore the filename would revert to the cloud's stored
  /// `original_name` — durable cloud rename is a v2 polish.
  Future<void> renameFile(String id, String newFilename) async {
    final db = await database;
    await db.update(
      'files',
      {'filename': newFilename},
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyListeners();
  }

  /// Patches the "captured" timestamp — surfaced by the info sheet's Edit
  /// affordance so users can correct a wrong date on an imported file. The
  /// EXIF DateTimeOriginal inside the encrypted blob is not modified (that
  /// would require re-encrypting), which is deliberate: the vault entry
  /// wins in the app, EXIF wins if the user ever exports.
  Future<void> updateCreatedAt(String id, DateTime captured) async {
    final db = await database;
    await db.update(
      'files',
      {'created_at': captured.millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyListeners();
  }

  Future<List<CnestFile>> getFavorites() async {
    final db = await database;
    if (_currentAccountId == null) return [];
    final maps = await db.query(
      'files',
      where: 'is_favorite = 1 AND account_id = ? AND is_deleted = 0',
      whereArgs: [_currentAccountId],
      orderBy: 'created_at DESC',
    );
    return maps.map((m) => CnestFile.fromMap(m)).toList();
  }

  /// Rows whose upload never completed (no cloud copy yet). When their local
  /// source is also gone they are phantom entries: nothing to decrypt,
  /// nothing to download. Auto-sync's healing pass re-uploads or purges them.
  Future<List<CnestFile>> getPendingUploads() async {
    final db = await database;
    if (_currentAccountId == null) return [];
    final maps = await db.query(
      'files',
      where: 'is_uploaded = 0 AND account_id = ? AND is_deleted = 0',
      whereArgs: [_currentAccountId],
    );
    return maps.map((m) => CnestFile.fromMap(m)).toList();
  }

  Future<List<CnestFile>> getFilesByType(CnestFileType type) async {
    final db = await database;
    if (_currentAccountId == null) return [];

    final List<Map<String, dynamic>> maps = await db.query(
      'files',
      where: 'type = ? AND account_id = ? AND is_deleted = 0',
      whereArgs: [type.index, _currentAccountId],
      orderBy: 'created_at DESC',
    );
    return List.generate(maps.length, (i) => CnestFile.fromMap(maps[i]));
  }

  // --- SYNC LOGIC (MAP ADAPTED) ---

  Future<void> reconcile(List<Map<String, dynamic>> cloudFiles) async {
    if (_currentAccountId == null) return; 

    final db = await database;
    final batch = db.batch();

    final cloudIds = cloudFiles.map((f) => f['id'] as String).toSet();
    final localRows = await db.query(
      'files', 
      columns: ['id', 'cloud_id'], 
      where: 'is_uploaded = 1 AND account_id = ?',
      whereArgs: [_currentAccountId]
    );
    
    for (var row in localRows) {
      final cloudId = row['cloud_id'] as String?;
      if (cloudId != null && !cloudIds.contains(cloudId)) {
        batch.delete('files', where: 'id = ?', whereArgs: [row['id']]);
      }
    }
    
    await batch.commit(noResult: true);
    final insertBatch = db.batch(); 

    final knownCloudIdsRows = await db.query(
      'files', 
      columns: ['cloud_id'], 
      where: 'cloud_id IS NOT NULL AND account_id = ?',
      whereArgs: [_currentAccountId]
    );
    final knownCloudIds = knownCloudIdsRows.map((r) => r['cloud_id']).toSet();

    final mainFiles = <Map<String, dynamic>>[];
    final thumbnailFiles = <Map<String, dynamic>>[];

    // Exclude the DB backup file from reconciliation
    cloudFiles.removeWhere((f) => f['name'] == 'ciphernest_db_backup.cnest');

    for (var file in cloudFiles) {
      final id = file['id'];
      final name = file['name'] as String? ?? '';

      if (name.endsWith('_thumb.cnest')) {
        thumbnailFiles.add(file);
      } else if (id != null && !knownCloudIds.contains(id)) {
        mainFiles.add(file);
      }
    }

    var unreadableMeta = 0;
    for (var file in mainFiles) {
      final name = file['name'] as String? ?? '';
      final stem = name.replaceAll('.cnest', '');

      // Name/type resolution ladder: HPKE-sealed metadata → transition-era
      // plaintext → UUID stem. An unopenable sealed blob (foreign vault key,
      // corruption) degrades to the UUID and gets counted for Vault Health —
      // it must never fail the sweep.
      final sealedMeta = file['sealed_meta'] as String?;
      final opened =
          sealedMeta == null ? null : await SealedMetadata.tryOpen(sealedMeta);
      final resolved = CloudNameResolver.resolve(
        hadSealed: sealedMeta != null,
        sealedOpened: opened,
        legacyName: file['original_name'] as String?,
        legacyType: file['type'] as String?,
        stem: stem,
      );
      if (resolved.unreadable) unreadableMeta++;
      final realFilename = resolved.name;
      final resolvedType = resolved.type;

      String localId = file['id'];
      if (name.endsWith('.cnest')) {
        localId = stem;
      }

      int size = 0;
      if (file['size'] is int) {
        size = file['size'];
      } else if (file['size'] is String) size = int.tryParse(file['size']) ?? 0;

      insertBatch.insert(
        'files',
        {
          'id': localId,
          'cloud_id': file['id'],
          'provider': AccountRegistry().activeAccount?.providerType ?? 0,
          'account_id': _currentAccountId,
          'filename': realFilename,
          'size_bytes': size,
          'created_at': file['created'] != null
              ? DateTime.parse(file['created']).millisecondsSinceEpoch
              : DateTime.now().millisecondsSinceEpoch,
          'is_uploaded': 1,
          'local_path': null,
          'type': resolvedType.index,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    
    await insertBatch.commit(noResult: true);
    final linkBatch = db.batch();

    for (var file in thumbnailFiles) {
      final name = file['name'] as String? ?? '';
      final parentFileId = name.replaceAll('_thumb.cnest', '');

      linkBatch.update(
        'files',
        {'thumbnail_cloud_id': file['id']},
        where: 'id = ?',
        whereArgs: [parentFileId],
      );
    }

    await linkBatch.commit(noResult: true);

    // Vault Health signal: sealed metadata that would not open this sweep.
    // Overwritten each sweep (not accumulated) so a healed vault clears it.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kMetaUnreadableCountPref, unreadableMeta);
  }

  /// Prefs key: how many vault blobs had sealed metadata that failed to open
  /// during the last reconcile. Surfaced in Settings (Vault Health).
  static const String kMetaUnreadableCountPref = 'vault_meta_unreadable_v1';

  Future<Map<String, int>> getStorageStats() async {
    final db = await database;
    // Use the composite account id ('${provider}_${email}') the rest of the
    // app stores in account_id. Earlier this used CloudService().currentEmail
    // (bare email) so the query matched zero rows.
    if (_currentAccountId == null) {
      return {
        'images': 0,
        'docs': 0,
        'audio': 0,
        'other': 0,
        'total_count': 0,
        'trash_bytes': 0,
        'trash_count': 0,
      };
    }

    // is_uploaded = 1 excludes files that are still mid-encrypt/mid-upload.
    // Without this, the vault-usage card jumps to the full file size the
    // instant the user picks it, then stays the same after upload finishes
    // — creating the illusion that a failed upload still counts.
    final countResult = await db.rawQuery(
      'SELECT COUNT(*) as count FROM files '
      'WHERE account_id = ? AND is_deleted = 0 AND is_uploaded = 1',
      [_currentAccountId],
    );
    final count = Sqflite.firstIntValue(countResult) ?? 0;

    final result = await db.rawQuery('''
      SELECT type, SUM(size_bytes) as total_size
      FROM files
      WHERE account_id = ? AND is_deleted = 0 AND is_uploaded = 1
      GROUP BY type
    ''', [_currentAccountId]);

    int imageBytes = 0;
    int docBytes = 0;
    int audioBytes = 0;
    int otherBytes = 0;

    for (var row in result) {
      final type = row['type'] as int;
      final size = row['total_size'] as int? ?? 0;
      // Match CnestFileType enum order: image=0, document=1, other=2, audio=3.
      switch (type) {
        case 0:
          imageBytes += size;
          break;
        case 1:
          docBytes += size;
          break;
        case 3:
          audioBytes += size;
          break;
        default:
          otherBytes += size;
      }
    }

    // Recycle Bin size — files that are soft-deleted but still costing
    // Drive/OneDrive quota until the 30-day sweeper hard-deletes them.
    // Surfaced separately so the vault-usage card can be honest about the
    // "0 B" case when items are actually still occupying cloud storage.
    final trashResult = await db.rawQuery(
      'SELECT COUNT(*) as cnt, SUM(size_bytes) as bytes FROM files '
      'WHERE account_id = ? AND is_deleted = 1 AND is_uploaded = 1',
      [_currentAccountId],
    );
    final trashCount = Sqflite.firstIntValue(trashResult) ?? 0;
    final trashBytes = (trashResult.isNotEmpty
        ? trashResult.first['bytes'] as int?
        : null) ?? 0;

    return {
      'images': imageBytes,
      'docs': docBytes,
      'audio': audioBytes,
      'other': otherBytes,
      'total_count': count,
      'trash_bytes': trashBytes,
      'trash_count': trashCount,
    };
  }

  Future<Map<String, String>> getCloudToLocalIdMap() async {
    final db = await database;
    if (_currentAccountId == null) return {};
    final rows = await db.query(
      'files',
      columns: ['id', 'cloud_id', 'thumbnail_cloud_id'],
      where: 'is_uploaded = 1 AND account_id = ? AND is_deleted = 0',
      whereArgs: [_currentAccountId],
    );
    final map = <String, String>{};
    for (final row in rows) {
      final localId = row['id'] as String;
      if (row['cloud_id'] != null) map[row['cloud_id'] as String] = localId;
      if (row['thumbnail_cloud_id'] != null) {
        map[row['thumbnail_cloud_id'] as String] = localId;
      }
    }
    return map;
  }

  // --- ALBUM OPERATIONS ---

  Future<List<CnestAlbum>> getAlbums({String kind = 'photo'}) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT a.*,
        CASE WHEN a.is_smart = 1 THEN 0
        ELSE (SELECT COUNT(*) FROM album_files af
              INNER JOIN files f ON f.id = af.file_id
              WHERE af.album_id = a.id AND f.is_deleted = 0)
        END as file_count
      FROM albums a
      WHERE a.kind = ?
      ORDER BY a.is_smart DESC, a.created_at ASC
    ''', [kind]);
    final albums = rows.map((r) => CnestAlbum.fromMap(r)).toList();

    // Populate smart album counts
    for (final album in albums) {
      if (album.isSmart) {
        album.fileCount = await _smartAlbumCount(db, album.smartQuery ?? '');
      }
    }
    return albums;
  }

  /// Music playlists — same tables as photo albums, kind = 'audio'.
  Future<List<CnestAlbum>> getPlaylists() => getAlbums(kind: 'audio');

  Future<CnestAlbum> createAlbum(String name, {String kind = 'photo'}) async {
    final db = await database;
    final now = DateTime.now();
    final album = CnestAlbum(
      id: const Uuid().v4(),
      name: name,
      kind: kind,
      createdAt: now,
      updatedAt: now,
    );
    await db.insert('albums', album.toMap());
    return album;
  }

  Future<CnestAlbum> createPlaylist(String name) =>
      createAlbum(name, kind: 'audio');

  Future<void> renameAlbum(String albumId, String newName) async {
    final db = await database;
    await db.update(
      'albums',
      {'name': newName, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ? AND is_smart = 0',
      whereArgs: [albumId],
    );
  }

  Future<void> deleteAlbum(String albumId) async {
    final db = await database;
    await db.delete('albums', where: 'id = ? AND is_smart = 0', whereArgs: [albumId]);
  }

  Future<void> setAlbumCover(String albumId, String fileId) async {
    final db = await database;
    await db.update(
      'albums',
      {'cover_file_id': fileId, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [albumId],
    );
  }

  Future<void> addFileToAlbum(String albumId, String fileId) async {
    final db = await database;
    await db.insert('album_files', {
      'album_id': albumId,
      'file_id': fileId,
      'added_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> addFilesToAlbum(String albumId, List<String> fileIds) async {
    final db = await database;
    final batch = db.batch();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final fileId in fileIds) {
      batch.insert('album_files', {
        'album_id': albumId,
        'file_id': fileId,
        'added_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }

  Future<void> removeFileFromAlbum(String albumId, String fileId) async {
    final db = await database;
    await db.delete(
      'album_files',
      where: 'album_id = ? AND file_id = ?',
      whereArgs: [albumId, fileId],
    );
  }

  Future<List<CnestFile>> getFilesForAlbum(CnestAlbum album) async {
    final db = await database;
    if (_currentAccountId == null) return [];

    if (album.isSmart) return _smartAlbumFiles(db, album.smartQuery ?? '');

    // Filter f.is_deleted = 0 so soft-deleted files stop appearing in
    // albums after a normal Delete action. The join-table row survives
    // (kept in case the file is restored from Recycle Bin), so this
    // filter is the single source of truth for album membership.
    final maps = await db.rawQuery('''
      SELECT f.* FROM files f
      INNER JOIN album_files af ON af.file_id = f.id
      WHERE af.album_id = ? AND f.account_id = ? AND f.is_deleted = 0
      ORDER BY f.created_at DESC
    ''', [album.id, _currentAccountId]);
    return maps.map((m) => CnestFile.fromMap(m)).toList();
  }

  Future<CnestFile?> getAlbumCoverFile(CnestAlbum album) async {
    final db = await database;
    if (_currentAccountId == null) return null;

    // Explicit cover set — but skip it if the referenced file has been
    // soft-deleted since the user picked it. Falls through to the "most
    // recent non-deleted file" path below.
    if (album.coverFileId != null) {
      final rows = await db.query('files',
          where: 'id = ? AND is_deleted = 0',
          whereArgs: [album.coverFileId],
          limit: 1);
      if (rows.isNotEmpty) return CnestFile.fromMap(rows.first);
    }

    // Fallback: most recent non-deleted file in the album.
    if (album.isSmart) {
      final files = await _smartAlbumFiles(db, album.smartQuery ?? '', limit: 1);
      return files.isNotEmpty ? files.first : null;
    }

    final maps = await db.rawQuery('''
      SELECT f.* FROM files f
      INNER JOIN album_files af ON af.file_id = f.id
      WHERE af.album_id = ? AND f.account_id = ? AND f.is_deleted = 0
      ORDER BY f.created_at DESC LIMIT 1
    ''', [album.id, _currentAccountId]);
    return maps.isNotEmpty ? CnestFile.fromMap(maps.first) : null;
  }

  // --- SMART ALBUM HELPERS ---

  Future<List<CnestFile>> _smartAlbumFiles(Database db, String query, {int? limit}) async {
    final where = _smartAlbumWhere(query);
    if (where == null) return [];
    final limitClause = limit != null ? ' LIMIT $limit' : '';
    final maps = await db.rawQuery(
      'SELECT * FROM files WHERE $where AND account_id = ? ORDER BY created_at DESC$limitClause',
      [_currentAccountId],
    );
    return maps.map((m) => CnestFile.fromMap(m)).toList();
  }

  Future<int> _smartAlbumCount(Database db, String query) async {
    final where = _smartAlbumWhere(query);
    if (where == null) return 0;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM files WHERE $where AND account_id = ?',
      [_currentAccountId],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  String? _smartAlbumWhere(String query) {
    // `is_deleted = 0` filter on every branch — the pre-S19 versions of
    // these queries returned soft-deleted files, so a photo the user had
    // moved to the Recycle Bin still showed up in All Photos.
    const notDeleted = 'is_deleted = 0';
    switch (query) {
      case 'all_images':
        return 'type = 0 AND $notDeleted';
      case 'camera':
        // Filename-based heuristic — good enough until we ingest bucket_name
        // from photo_manager (Samsung Camera stores photos as YYYYMMDD_HHMMSS.jpg
        // with no IMG_ prefix; the old query missed those entirely).
        //   IMG_*   — Samsung old / Google / OnePlus / iPhone naming
        //   PXL_*   — Pixel Camera
        //   DSC*    — DSLRs
        //   20YY-* / 20YYMMDD_* / 20YY_* — Samsung Camera modern naming
        return "type = 0 AND $notDeleted AND ("
            "LOWER(filename) LIKE 'img_%' OR "
            "LOWER(filename) LIKE 'pxl_%' OR "
            "LOWER(filename) LIKE 'dsc%' OR "
            "filename LIKE '20__-__-__%' OR "
            "filename LIKE '20______\\_%' ESCAPE '\\' OR "
            "filename LIKE '20______-%' OR "
            "LOWER(filename) LIKE '%dcim%' OR "
            "LOWER(filename) LIKE '%camera%'"
            ")";
      case 'screenshots':
        return "type = 0 AND $notDeleted AND LOWER(filename) LIKE '%screenshot%'";
      case 'videos':
        return "type = 0 AND $notDeleted AND ("
            "LOWER(filename) LIKE '%.mp4' OR "
            "LOWER(filename) LIKE '%.mov' OR "
            "LOWER(filename) LIKE '%.avi' OR "
            "LOWER(filename) LIKE '%.mkv' OR "
            "LOWER(filename) LIKE '%.webm'"
            ")";
      // Music smart playlists. type 3 = CnestFileType.audio.
      case 'audio_recent':
        return 'type = 3 AND $notDeleted';
      case 'audio_favourites':
        return 'type = 3 AND is_favorite = 1 AND $notDeleted';
      default:
        return null;
    }
  }

  // --- FEATURED CONTENT ---

  Future<List<CnestFile>> getFilesFromOneYearAgo({int dayRange = 3}) async {
    final db = await database;
    if (_currentAccountId == null) return [];

    final now = DateTime.now();
    final yearAgo = DateTime(now.year - 1, now.month, now.day);
    final minMs = yearAgo.subtract(Duration(days: dayRange)).millisecondsSinceEpoch;
    final maxMs = yearAgo.add(Duration(days: dayRange)).millisecondsSinceEpoch;

    // is_deleted = 0 — soft-deleted photos must not resurface as "a year
    // ago" memories. Without this filter, deleting an old embarrassing
    // photo has no effect on next year's Stories tab.
    final maps = await db.query(
      'files',
      where: 'type = 0 AND account_id = ? AND is_deleted = 0 '
          'AND created_at BETWEEN ? AND ?',
      whereArgs: [_currentAccountId, minMs, maxMs],
      orderBy: 'created_at DESC',
    );
    return maps.map((m) => CnestFile.fromMap(m)).toList();
  }

  // --- SHARE OPERATIONS ---

  Future<void> addShare(CnestShare share) async {
    final db = await database;
    await db.insert('shares', share.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<CnestShare>> getShares() async {
    final db = await database;
    if (_currentAccountId == null) return [];
    final rows = await db.query(
      'shares',
      where: 'account_id = ?',
      whereArgs: [_currentAccountId],
      orderBy: 'created_at DESC',
    );
    return rows.map((r) => CnestShare.fromMap(r)).toList();
  }

  Future<CnestShare?> getShareById(String id) async {
    final db = await database;
    final rows = await db.query(
      'shares',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return CnestShare.fromMap(rows.first);
  }

  Future<void> deleteShare(String id) async {
    final db = await database;
    await db.delete('shares', where: 'id = ?', whereArgs: [id]);
  }
}