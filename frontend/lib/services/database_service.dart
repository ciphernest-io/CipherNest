import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../src/models/file_model.dart';
import 'drive_service.dart';
import 'package:googleapis/drive/v3.dart' as drive;

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
    // Force the current account ID onto the file
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

  Future<void> deleteFile(String id) async {
    final db = await database;
    await db.delete('files', where: 'id = ?', whereArgs: [id]);
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

  Future<List<CnestFile>> getFilesByType(CnestFileType type) async {
    final db = await database;
    
    // Safety: If no account is set, return empty to avoid leaking or showing wrong data
    if (_currentAccountId == null) {
      return [];
    }

    final List<Map<String, dynamic>> maps = await db.query(
      'files',
      where: 'type = ? AND account_id = ?',
      whereArgs: [type.index, _currentAccountId],
      orderBy: 'created_at DESC',
    );
    return List.generate(maps.length, (i) => CnestFile.fromMap(maps[i]));
  }

  // --- SYNC LOGIC ---

  Future<void> reconcile(List<drive.File> cloudFiles) async {
    if (_currentAccountId == null) return; 

    final db = await database;
    final batch = db.batch();

    // --- PHASE A: CLEANUP (Remove deleted files) ---
    final cloudIds = cloudFiles.map((f) => f.id).whereType<String>().toSet();
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
    
    // Commit deletes first to clear space
    await batch.commit(noResult: true);
    final insertBatch = db.batch(); // New batch for inserts

    // --- PHASE B: SEPARATION ---
    final knownCloudIdsRows = await db.query(
      'files', 
      columns: ['cloud_id'], 
      where: 'cloud_id IS NOT NULL AND account_id = ?',
      whereArgs: [_currentAccountId]
    );
    final knownCloudIds = knownCloudIdsRows.map((r) => r['cloud_id']).toSet();

    // Split files into "Main" and "Thumbnails"
    final mainFiles = <drive.File>[];
    final thumbnailFiles = <drive.File>[];

    for (var file in cloudFiles) {
      if (file.id == null || knownCloudIds.contains(file.id)) continue;
      
      final name = file.name ?? '';
      if (name.endsWith('_thumb.cnest')) {
        thumbnailFiles.add(file);
      } else {
        mainFiles.add(file);
      }
    }

    // --- PHASE C: IMPORT MAIN FILES (Pass 1) ---
    for (var file in mainFiles) {
      final props = file.appProperties ?? {};
      final realFilename = props['original_name'] ?? 'Restored File';
      final typeStr = props['type'] ?? '';
      
      bool isImage = false;
      if (typeStr == 'image') isImage = true;
      else if (typeStr == 'document') isImage = false;
      else isImage = (file.name ?? '').contains('photo');

      String localId = file.id!;
      if (file.name != null && file.name!.endsWith('.cnest')) {
         localId = file.name!.replaceAll('.cnest', '');
      }

      insertBatch.insert(
        'files',
        {
          'id': localId,
          'cloud_id': file.id,
          'provider': 0,
          'account_id': _currentAccountId, 
          'filename': realFilename, 
          'size_bytes': int.tryParse(file.size ?? '0') ?? 0,
          'created_at': file.createdTime?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch,
          'is_uploaded': 1,
          'local_path': null,
          'type': isImage ? 0 : 1,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    
    // Commit Main Files immediately so they exist for Phase D
    await insertBatch.commit(noResult: true);
    final linkBatch = db.batch();

    // --- PHASE D: LINK THUMBNAILS (Pass 2) ---
    for (var file in thumbnailFiles) {
      final name = file.name ?? '';
      // Extract UUID: "abc-123_thumb.cnest" -> "abc-123"
      final parentFileId = name.replaceAll('_thumb.cnest', '');
      
      linkBatch.update(
        'files',
        {'thumbnail_cloud_id': file.id},
        where: 'id = ?',
        whereArgs: [parentFileId],
      );
    }

    await linkBatch.commit(noResult: true);
  }

  // Add this to DatabaseService class
  Future<Map<String, int>> getStorageStats() async {
    final db = await database;
    final email = DriveService.currentEmail;
    if (email == null) return {'images': 0, 'docs': 0, 'total_count': 0};

    // 1. Get Total File Count
    final countResult = await db.rawQuery(
      'SELECT COUNT(*) as count FROM files WHERE account_id = ?', 
      [email]
    );
    final count = Sqflite.firstIntValue(countResult) ?? 0;

    // 2. Get Size by Type (0 = Image, 1 = Document)
    // We sum up the 'size_bytes' column
    final List<Map<String, dynamic>> result = await db.rawQuery('''
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
      
      if (type == 0) { // CnestFileType.image.index
        imageBytes = size;
      } else {
        docBytes += size; // Combine docs + others
      }
    }

    return {
      'images': imageBytes,
      'docs': docBytes,
      'total_count': count,
    };
  }
}