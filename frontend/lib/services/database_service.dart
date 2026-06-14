import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../src/models/file_model.dart';
import '../src/models/album_model.dart';
import '../src/models/share_model.dart';
import 'cloud/account_registry.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  Database? _database;
  String? _currentAccountId; 

  void setCurrentAccount(String email) {
    _currentAccountId = email;
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
      version: 7,
      onCreate: (db, version) async {
        await _createSchema(db);
        await _seedSmartAlbums(db);
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
  }

  /// Soft-delete: hides the row from every gallery query and stamps the
  /// deletion time so the Recycle Bin can show "X days left" and the sweep
  /// can purge it after the TTL. The encrypted cloud blob is left alone so
  /// restores are instant and offline.
  Future<void> deleteFile(String id) async {
    final db = await database;
    await db.update(
      'files',
      {
        'is_deleted': 1,
        'deleted_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Hard delete — used by the Recycle Bin "Delete forever" path and by the
  /// 30-day sweeper. Callers are responsible for the cloud blob and any
  /// cached artifacts; this only removes the SQLite row.
  Future<void> permanentlyDeleteFile(String id) async {
    final db = await database;
    await db.delete('files', where: 'id = ?', whereArgs: [id]);
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

    for (var file in mainFiles) {
      final name = file['name'] as String? ?? '';
      final realFilename = file['original_name'] as String? ?? name.replaceAll('.cnest', '');
      final typeStr = file['type'] as String?;

      // Prefer the cloud-side wire string. Fall back to extension inference
      // for: (a) older blobs that pre-date the audio/other tags, (b) blobs
      // mis-tagged as `document` by the early build (which lumped everything
      // non-image into documents). Extension inference auto-heals music files
      // and misc binaries that would otherwise live in the wrong tab.
      CnestFileType resolvedType = CnestFileTypeWire.fromWire(typeStr) ??
          CnestFileTypeWire.fromFilename(realFilename);
      if (resolvedType == CnestFileType.document) {
        final inferred = CnestFileTypeWire.fromFilename(realFilename);
        if (inferred == CnestFileType.audio || inferred == CnestFileType.image) {
          resolvedType = inferred;
        }
      }

      String localId = file['id'];
      if (name.endsWith('.cnest')) {
         localId = name.replaceAll('.cnest', '');
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
  }

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
      };
    }

    final countResult = await db.rawQuery(
      'SELECT COUNT(*) as count FROM files WHERE account_id = ? AND is_deleted = 0',
      [_currentAccountId],
    );
    final count = Sqflite.firstIntValue(countResult) ?? 0;

    final result = await db.rawQuery('''
      SELECT type, SUM(size_bytes) as total_size
      FROM files
      WHERE account_id = ? AND is_deleted = 0
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

    return {
      'images': imageBytes,
      'docs': docBytes,
      'audio': audioBytes,
      'other': otherBytes,
      'total_count': count,
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

  Future<List<CnestAlbum>> getAlbums() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT a.*,
        CASE WHEN a.is_smart = 1 THEN 0
        ELSE (SELECT COUNT(*) FROM album_files af WHERE af.album_id = a.id)
        END as file_count
      FROM albums a
      ORDER BY a.is_smart DESC, a.created_at ASC
    ''');
    final albums = rows.map((r) => CnestAlbum.fromMap(r)).toList();

    // Populate smart album counts
    for (final album in albums) {
      if (album.isSmart) {
        album.fileCount = await _smartAlbumCount(db, album.smartQuery ?? '');
      }
    }
    return albums;
  }

  Future<CnestAlbum> createAlbum(String name) async {
    final db = await database;
    final now = DateTime.now();
    final album = CnestAlbum(
      id: const Uuid().v4(),
      name: name,
      createdAt: now,
      updatedAt: now,
    );
    await db.insert('albums', album.toMap());
    return album;
  }

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

    final maps = await db.rawQuery('''
      SELECT f.* FROM files f
      INNER JOIN album_files af ON af.file_id = f.id
      WHERE af.album_id = ? AND f.account_id = ?
      ORDER BY f.created_at DESC
    ''', [album.id, _currentAccountId]);
    return maps.map((m) => CnestFile.fromMap(m)).toList();
  }

  Future<CnestFile?> getAlbumCoverFile(CnestAlbum album) async {
    final db = await database;
    if (_currentAccountId == null) return null;

    // Explicit cover set
    if (album.coverFileId != null) {
      final rows = await db.query('files',
          where: 'id = ?', whereArgs: [album.coverFileId], limit: 1);
      if (rows.isNotEmpty) return CnestFile.fromMap(rows.first);
    }

    // Fallback: most recent file in the album
    if (album.isSmart) {
      final files = await _smartAlbumFiles(db, album.smartQuery ?? '', limit: 1);
      return files.isNotEmpty ? files.first : null;
    }

    final maps = await db.rawQuery('''
      SELECT f.* FROM files f
      INNER JOIN album_files af ON af.file_id = f.id
      WHERE af.album_id = ? AND f.account_id = ?
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
    switch (query) {
      case 'all_images':
        return 'type = 0';
      case 'camera':
        return "type = 0 AND (LOWER(filename) LIKE '%img_%' OR LOWER(filename) LIKE '%dcim%' OR LOWER(filename) LIKE '%camera%')";
      case 'screenshots':
        return "type = 0 AND LOWER(filename) LIKE '%screenshot%'";
      case 'videos':
        return "type = 0 AND (LOWER(filename) LIKE '%.mp4' OR LOWER(filename) LIKE '%.mov' OR LOWER(filename) LIKE '%.avi' OR LOWER(filename) LIKE '%.mkv')";
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

    final maps = await db.query(
      'files',
      where: 'type = 0 AND account_id = ? AND created_at BETWEEN ? AND ?',
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