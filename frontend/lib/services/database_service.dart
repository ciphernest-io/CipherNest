import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../src/models/file_model.dart';
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

  Future<void> markAsUploaded(String id, String cloudId) async {
    final db = await database;
    await db.update(
      'files',
      {
        'is_uploaded': 1,
        'cloud_id': cloudId,
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

    // A. CLEANUP 
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

    // B. IMPORT 
    final knownCloudIdsRows = await db.query(
      'files', 
      columns: ['cloud_id'], 
      where: 'cloud_id IS NOT NULL AND account_id = ?',
      whereArgs: [_currentAccountId]
    );
    final knownCloudIds = knownCloudIdsRows.map((r) => r['cloud_id']).toSet();

    for (var file in cloudFiles) {
      if (file.id == null || knownCloudIds.contains(file.id)) continue;

      // FIX: Check metadata first, fallback to name
      final props = file.appProperties ?? {};
      final realFilename = props['original_name'] ?? 'Restored File';
      final typeStr = props['type'] ?? '';
      
      bool isImage = false;
      if (typeStr == 'image') {
        isImage = true;
      } else if (typeStr == 'document') {
        isImage = false;
      } else {
        // Fallback for legacy files
        final name = file.name ?? 'Unknown';
        isImage = name.toLowerCase().contains('.jpg') || 
                  name.toLowerCase().contains('.png') ||
                  name.toLowerCase().contains('photo');
      }

      batch.insert(
        'files',
        {
          'id': file.id!,
          'cloud_id': file.id,
          'provider': 0,
          'account_id': _currentAccountId, 
          'filename': realFilename, 
          'size_bytes': int.tryParse(file.size ?? '0') ?? 0,
          'created_at': file.createdTime?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch,
          'is_uploaded': 1,
          'local_path': null,
          'type': isImage ? 0 : 1, // 0 = Image
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }

    await batch.commit(noResult: true);
  }
}