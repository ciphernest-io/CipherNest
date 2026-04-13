import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../src/models/file_model.dart';
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

    return await openDatabase(
      path,
      version: 1,
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
      },
    );
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
        'local_path': null, 
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
}