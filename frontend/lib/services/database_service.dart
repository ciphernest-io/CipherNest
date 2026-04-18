import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../src/models/file_model.dart';
import '../src/models/album_model.dart';
import 'cloud/cloud_service.dart';

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
      version: 2,
      onCreate: (db, version) async {
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
            type INTEGER
          )
        ''');
        await _createAlbumTables(db);
        await _seedSmartAlbums(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createAlbumTables(db);
          await _seedSmartAlbums(db);
        }
      },
    );
    await db.execute('PRAGMA foreign_keys = ON');
    return db;
  }

  static Future<void> _createAlbumTables(Database db) async {
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
      provider: 0, 
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

  Future<void> deleteFile(String id) async {
    final db = await database;
    await db.delete('files', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<CnestFile>> getFilesByType(CnestFileType type) async {
    final db = await database;
    if (_currentAccountId == null) return [];

    final List<Map<String, dynamic>> maps = await db.query(
      'files',
      where: 'type = ? AND account_id = ?',
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
      
      bool isImage = false;
      if (typeStr == 'image') isImage = true;
      else if (typeStr == 'document') isImage = false;
      else isImage = name.contains('photo');

      String localId = file['id'];
      if (name.endsWith('.cnest')) {
         localId = name.replaceAll('.cnest', '');
      }

      int size = 0;
      if (file['size'] is int) size = file['size'];
      else if (file['size'] is String) size = int.tryParse(file['size']) ?? 0;

      insertBatch.insert(
        'files',
        {
          'id': localId,
          'cloud_id': file['id'],
          'provider': 0,
          'account_id': _currentAccountId, 
          'filename': realFilename, 
          'size_bytes': size,
          'created_at': file['created'] != null 
              ? DateTime.parse(file['created']).millisecondsSinceEpoch 
              : DateTime.now().millisecondsSinceEpoch,
          'is_uploaded': 1,
          'local_path': null,
          'type': isImage ? 0 : 1,
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
    final email = CloudService().currentEmail;
    if (email == null) return {'images': 0, 'docs': 0, 'total_count': 0};

    final countResult = await db.rawQuery(
      'SELECT COUNT(*) as count FROM files WHERE account_id = ?', 
      [email]
    );
    final count = Sqflite.firstIntValue(countResult) ?? 0;

    final result = await db.rawQuery('''
      SELECT type, SUM(size_bytes) as total_size 
      FROM files 
      WHERE account_id = ? 
      GROUP BY type
    ''', [email]);

    int imageBytes = 0;
    int docBytes = 0;

    for (var row in result) {
      final type = row['type'] as int;
      final size = row['total_size'] as int? ?? 0;
      if (type == 0) imageBytes = size;
      else docBytes += size;
    }

    return {
      'images': imageBytes,
      'docs': docBytes,
      'total_count': count,
    };
  }

  Future<Map<String, String>> getCloudToLocalIdMap() async {
    final db = await database;
    final rows = await db.query(
      'files',
      columns: ['id', 'cloud_id', 'thumbnail_cloud_id'],
      where: 'is_uploaded = 1',
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
}