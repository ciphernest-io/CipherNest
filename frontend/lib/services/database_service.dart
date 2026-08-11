import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../src/models/file_model.dart';
import '../src/models/folder_model.dart';
import '../src/models/album_model.dart';
import '../src/models/share_model.dart';
import 'cache_manager_service.dart';
import 'cloud/account_registry.dart';
import 'cloud/sealed_metadata.dart';
import 'sync/sync_coordinator.dart';
import 'sync/sync_op.dart';

/// [DatabaseService] extends [ChangeNotifier] so screens can rebuild in-place
/// when files are added, deleted, restored, or moved between albums. Every
/// mutating write ends with [notifyListeners]; every list-rendering screen
/// subscribes with [addListener] in initState and unsubscribes in dispose.
/// This kills the pull-to-refresh requirement after a delete.
/// See [DatabaseService.getAutoSyncDedupIndex].
class AutoSyncDedupIndex {
  final Set<String> uploadedKeys;
  final Set<String> knownAssetIds;
  final Set<String> inFlightKeys;

  const AutoSyncDedupIndex({
    required this.uploadedKeys,
    required this.knownAssetIds,
    required this.inFlightKeys,
  });

  const AutoSyncDedupIndex.empty()
      : uploadedKeys = const {},
        knownAssetIds = const {},
        inFlightKeys = const {};
}

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

  /// External-change signal for services that rewrite rows outside this
  /// class (SyncEngine.applyMergedState) so screens rebuild in place.
  void notifyFilesChanged() => notifyListeners();

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
      version: 17,
      onCreate: (db, version) async {
        await _createSchema(db);
        await _createSyncSchema(db);
        await _seedSmartAlbums(db);
        await _seedSmartPlaylists(db);
      },
      onUpgrade: (db, oldVersion, newVersion) => _migrate(db, oldVersion),
    );
    await db.execute('PRAGMA foreign_keys = ON');
    return db;
  }

  /// Injects an already-open database (tests only) so instance methods like
  /// [reconcile] run against a real in-memory SQLite instead of the device
  /// file.
  @visibleForTesting
  void debugSetDatabase(Database db) {
    _database = db;
  }

  /// Runs the REAL migration chain on [db] — exposed so tests can verify
  /// upgrade == fresh-create column-for-column.
  @visibleForTesting
  static Future<void> migrateForTest(Database db, int oldVersion) =>
      _migrate(db, oldVersion);

  /// Runs the REAL current-version schema DDL on [db] (files/albums/shares).
  @visibleForTesting
  static Future<void> createSchemaForTest(Database db) => _createSchema(db);

  static Future<void> _migrate(Database db, int oldVersion) async {
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
        // v9 adds the multi-device sync op-log tables (Stage 2d). SQLite
        // becomes a MATERIALIZED VIEW of the op-log for op-derived fields;
        // see SyncEngine.applyMergedState.
        if (oldVersion < 9) {
          await _createSyncSchema(db);
        }
        // v10 adds content_hash — SHA-256 of plaintext, the file's true
        // identity (fix for "filename is not identity"). Existing rows get
        // NULL; verification degrades to size-only until they're re-hashed.
        // The createFile op also gains content_hash + size_bytes (identity +
        // expected size for a peer before the blob is joined).
        if (oldVersion < 10) {
          await db.execute('ALTER TABLE files ADD COLUMN content_hash TEXT');
          // sync_ops may not exist yet if jumping from a very old version;
          // the v9 branch above creates it, so guard with a column probe.
          final cols = await db.rawQuery('PRAGMA table_info(sync_ops)');
          final hasHash = cols.any((c) => c['name'] == 'content_hash');
          if (!hasHash) {
            await db.execute(
                'ALTER TABLE sync_ops ADD COLUMN content_hash TEXT');
            await db.execute(
                'ALTER TABLE sync_ops ADD COLUMN size_bytes INTEGER');
          }
        }
        // v11 adds captured_at to the createFile op — the media's capture
        // time (EXIF DateTimeOriginal / MediaStore DATE_TAKEN), so every
        // device sorts the gallery by an identical, clock-skew-immune key.
        // Existing ops lack it and fall back to the create op's HLC wall.
        if (oldVersion < 11) {
          final cols = await db.rawQuery('PRAGMA table_info(sync_ops)');
          final hasCaptured = cols.any((c) => c['name'] == 'captured_at');
          if (!hasCaptured) {
            await db.execute(
                'ALTER TABLE sync_ops ADD COLUMN captured_at INTEGER');
          }
        }
        // v12: upload_started_at — wall-clock of the last upload ATTEMPT
        // (created_at is CAPTURE time, so heal-grace math needs its own
        // stamp) — plus media dimensions/duration captured at upload time
        // so the details sheet works for files with no gallery counterpart.
        if (oldVersion < 12) {
          await db.execute(
              'ALTER TABLE files ADD COLUMN upload_started_at INTEGER');
          await db.execute('ALTER TABLE files ADD COLUMN width INTEGER');
          await db.execute('ALTER TABLE files ADD COLUMN height INTEGER');
          await db.execute('ALTER TABLE files ADD COLUMN duration_ms INTEGER');
        }
        // v13: video codec / audio codec / fps — the rest of the details
        // sheet's video row, captured at upload time like the v12 fields.
        // Local-only; the createFile op is unchanged.
        if (oldVersion < 13) {
          await db.execute('ALTER TABLE files ADD COLUMN video_codec TEXT');
          await db.execute('ALTER TABLE files ADD COLUMN audio_codec TEXT');
          await db.execute('ALTER TABLE files ADD COLUMN fps INTEGER');
        }
        // v14: device_model — the recording device, read from the video's
        // moov/udta vendor atoms (Samsung's "Galaxy A55 5G") at upload
        // time. Completes the Samsung-parity details row for videos whose
        // gallery original is gone.
        if (oldVersion < 14) {
          await db.execute('ALTER TABLE files ADD COLUMN device_model TEXT');
        }
        // v15: the virtual folder tree (Model A). `folders` + both new
        // files columns are MATERIALIZED VIEW state, written exclusively by
        // SyncEngine.applyMergedState from the op-log:
        //  * files.folder_id — live location, normalized live-or-root at
        //    write time (raw pointers live only in the log).
        //  * files.deleted_by_folder_id / folders.deleted_by_folder_id —
        //    the EXPLICIT cascade cause (the targeted root of the
        //    deleteFolder that binned this item; NULL = individual delete).
        //    The bin's type tabs filter on it and restoreFolder restores by
        //    it — never inferred from a missing timestamp.
        if (oldVersion < 15) {
          await db.execute('ALTER TABLE files ADD COLUMN folder_id TEXT');
          await db.execute(
              'ALTER TABLE files ADD COLUMN deleted_by_folder_id TEXT');
          await db.execute(_createFoldersTableSql);
          await db.execute(_createFoldersIndexSql);
          await db.execute(_createFilesFolderIndexSql);
        }
        // v16: folders.is_system — 1 for the auto-sync "Phone Backup" tree.
        // Derived (id prefix, see SystemFolders) and stamped by
        // applyMergedState's derived map, so it converges by construction.
        // Guard: a <15 upgrade just created the table WITH the column.
        if (oldVersion < 16 && oldVersion >= 15) {
          await db.execute(
              'ALTER TABLE folders ADD COLUMN is_system INTEGER NOT NULL '
              'DEFAULT 0');
        }
        // v17: per-folder "hide from specialized views" (synced op) plus the
        // materialized subtree flag. Guard: a <15 upgrade just created the
        // table WITH both columns.
        if (oldVersion < 17 && oldVersion >= 15) {
          await db.execute(
              'ALTER TABLE folders ADD COLUMN is_hidden INTEGER NOT NULL '
              'DEFAULT 0');
          await db.execute(
              'ALTER TABLE folders ADD COLUMN hidden_effective INTEGER NOT '
              'NULL DEFAULT 0');
        }
  }

  /// The virtual folder tree (v15). Fully op-derived — every row is
  /// written by applyMergedState; there is no reconcile for folders (no
  /// blobs) and no op-less legacy rows, so the table is always an exact
  /// function of the log. Deleted folders KEEP their rows (the Recycle Bin
  /// shows them); only a purgeFolder op removes one.
  static const String _createFoldersTableSql = '''
      CREATE TABLE IF NOT EXISTS folders(
        id TEXT PRIMARY KEY,
        account_id TEXT NOT NULL,
        name TEXT NOT NULL,
        parent_id TEXT,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        deleted_at INTEGER,
        deleted_by_folder_id TEXT,
        created_at INTEGER,
        is_system INTEGER NOT NULL DEFAULT 0,
        is_hidden INTEGER NOT NULL DEFAULT 0,
        hidden_effective INTEGER NOT NULL DEFAULT 0
      )
    ''';

  static const String _createFoldersIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_folders_account '
      'ON folders(account_id, parent_id)';

  static const String _createFilesFolderIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_files_folder '
      'ON files(account_id, folder_id)';

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

  /// Runs the REAL sync-table DDL on [db] — so engine tests exercise the
  /// production schema, not a hand-copied one that can drift.
  @visibleForTesting
  static Future<void> createSyncSchemaForTest(Database db) =>
      _createSyncSchema(db);

  /// Multi-device sync op-log storage (Stage 2d).
  ///
  ///  * `sync_ops` — the local cache of the append-only log, plus this
  ///    device's not-yet-uploaded ops (`pending = 1`). Crash-safe pending
  ///    queue: a process death never loses a recorded user action.
  ///  * `sync_seen_segments` — cloud segment names already merged.
  ///  * `sync_state` — per-account HLC/seq/segment counters.
  static Future<void> _createSyncSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_ops(
        op_key TEXT PRIMARY KEY,
        account_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        hlc_wall INTEGER NOT NULL,
        hlc_counter INTEGER NOT NULL,
        kind TEXT NOT NULL,
        target_id TEXT NOT NULL,
        name TEXT,
        folder_id TEXT,
        favorite INTEGER,
        content_hash TEXT,
        size_bytes INTEGER,
        captured_at INTEGER,
        pending INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sync_ops_account ON sync_ops(account_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sync_ops_pending ON sync_ops(account_id, pending)');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_seen_segments(
        account_id TEXT NOT NULL,
        name TEXT NOT NULL,
        PRIMARY KEY (account_id, name)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_state(
        account_id TEXT PRIMARY KEY,
        hlc_wall INTEGER NOT NULL DEFAULT 0,
        hlc_counter INTEGER NOT NULL DEFAULT 0,
        next_seq INTEGER NOT NULL DEFAULT 0,
        next_segment INTEGER NOT NULL DEFAULT 0,
        last_pull_wall INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

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
        type INTEGER,
        content_hash TEXT,
        upload_started_at INTEGER,
        width INTEGER,
        height INTEGER,
        duration_ms INTEGER,
        video_codec TEXT,
        audio_codec TEXT,
        fps INTEGER,
        device_model TEXT,
        folder_id TEXT,
        deleted_by_folder_id TEXT
      )
    ''');
    await db.execute(_createFoldersTableSql);
    await db.execute(_createFoldersIndexSql);
    await db.execute(_createFilesFolderIndexSql);
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
      assetId: file.assetId,
      isUploaded: file.isUploaded,
      cloudId: file.cloudId,
      thumbnailCloudId: file.thumbnailCloudId,
      provider: AccountRegistry().activeAccount?.providerType ?? 0,
      accountId: _currentAccountId,
      contentHash: file.contentHash,
      width: file.width,
      height: file.height,
      durationMs: file.durationMs,
      videoCodec: file.videoCodec,
      audioCodec: file.audioCodec,
      fps: file.fps,
      deviceModel: file.deviceModel,
      // Every addFile caller is starting an upload attempt right now —
      // stamp it so heal grace measures from THIS moment, not capture time.
      uploadStartedAt: DateTime.now().millisecondsSinceEpoch,
    );

    await db.insert(
      'files',
      fileWithAccount.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    notifyListeners();
  }

  /// Re-stamps the upload-attempt clock on an existing pending row — used
  /// when heal retries a row in place instead of delete-and-recreate.
  Future<void> touchUploadAttempt(String id) async {
    final db = await database;
    await db.update(
      'files',
      {'upload_started_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Marks the blob durably uploaded — and ONLY here does the file's
  /// createFile op enter the sync log, preserving crash ordering (blob
  /// before op: a crash in between leaves an orphan blob, never a
  /// dangling reference). [filename] comes from the caller's in-flight
  /// action context — never read back from a row.
  Future<void> markAsUploaded(
    String id,
    String cloudId,
    String? thumbId, {
    String? filename,
    String? contentHash,
    int? sizeBytes,
    int? capturedAt,
    String? folderId,
  }) async {
    final db = await database;
    final updated = await db.update(
      'files',
      {
        'is_uploaded': 1,
        'cloud_id': cloudId,
        'thumbnail_cloud_id': thumbId,
        if (contentHash != null) 'content_hash': contentHash,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    // Row vanished mid-upload (heal or a concurrent delete beat us). A
    // createFile op for a row that no longer exists would ship a dangling
    // reference to every peer — never record one.
    if (updated == 0) {
      debugPrint('markAsUploaded: row $id gone — createFile op NOT recorded');
      notifyListeners();
      return;
    }
    if (filename != null) {
      // The createFile op carries the content hash (identity / dedup), the
      // plaintext size (so a peer shows the right size immediately), and the
      // capture time (so every device sorts the gallery identically).
      await SyncCoordinator().record(
        SyncOpKind.createFile,
        id,
        name: filename,
        hash: contentHash,
        size: sizeBytes,
        captured: capturedAt,
        folderId: folderId,
      );
    }
    notifyListeners();
  }

  /// Hard-removes a row WITHOUT recording a sync op — for rolling back a
  /// failed/never-completed upload. Such a file never recorded a createFile
  /// op (that happens in [markAsUploaded]), so there is nothing to converge
  /// and a purge op would be spurious. Just erase the phantom row.
  Future<void> rollbackFailedUpload(String id) async {
    final db = await database;
    await db.delete('files', where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  /// Clears the local-gallery references (`local_path`, `asset_id`) for a
  /// file — used after a replace-original edit, whose new bytes have no
  /// counterpart in the phone gallery, so the display shortcut must fall
  /// through to the (edited) cloud blob instead of the stale original.
  Future<void> clearLocalRefs(String id) async {
    final db = await database;
    await db.update(
      'files',
      {'local_path': null, 'asset_id': null},
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
    await SyncCoordinator().record(SyncOpKind.deleteFile, id);
    notifyListeners();
  }

  /// Hard delete — used by the Recycle Bin "Delete forever" path and by the
  /// 30-day sweeper. Callers are responsible for the cloud blob and any
  /// cached artifacts; this only removes the SQLite row.
  ///
  /// Records a terminal `purgeFile` sync op so the permanent deletion
  /// CONVERGES: without it, a device that swept the row and a device that
  /// still holds the tombstone would disagree forever. Purge wins over any
  /// later restore in replay — the blob is physically gone.
  Future<void> permanentlyDeleteFile(String id) async {
    final db = await database;
    await db.delete('files', where: 'id = ?', whereArgs: [id]);
    await SyncCoordinator().record(SyncOpKind.purgeFile, id);
    notifyListeners();
  }

  /// Soft-deleted rows for the current account, most-recently-trashed
  /// first. INDIVIDUAL entries only by default: cascade-binned files
  /// (deleted_by_folder_id pointing at an existing folder row) belong to
  /// their folder's single bin entry — deleting a 500-photo folder must not
  /// flood the Photos tab with 500 rows. Orphaned causes (folder row gone —
  /// an interrupted purge batch) fall back to individual display so nothing
  /// becomes unreachable. Pass [type] to scope to one bin tab.
  Future<List<CnestFile>> getDeletedFiles({CnestFileType? type}) async {
    final db = await database;
    if (_currentAccountId == null) return [];
    final maps = await db.query(
      'files',
      where: 'is_deleted = 1 AND account_id = ? AND '
          '(deleted_by_folder_id IS NULL OR '
          'deleted_by_folder_id NOT IN (SELECT id FROM folders))'
          '${type != null ? ' AND type = ?' : ''}',
      whereArgs: [
        _currentAccountId,
        if (type != null) type.index,
      ],
      orderBy: 'deleted_at DESC',
    );
    return maps.map((m) => CnestFile.fromMap(m)).toList();
  }

  /// Binned files a folder's delete cascade owns — the drill-in contents.
  Future<List<CnestFile>> getCascadeBinnedFiles(String folderId) async {
    final db = await database;
    if (_currentAccountId == null) return [];
    final maps = await db.query(
      'files',
      where:
          'account_id = ? AND is_deleted = 1 AND deleted_by_folder_id = ?',
      whereArgs: [_currentAccountId, folderId],
      orderBy: 'created_at DESC',
    );
    return maps.map((m) => CnestFile.fromMap(m)).toList();
  }

  /// Cascade-binned subfolders of a deleted folder (cause = the targeted
  /// root, whatever the nesting depth).
  Future<List<CnestFolder>> getCascadeBinnedFolders(String folderId) async {
    final db = await database;
    if (_currentAccountId == null) return [];
    final rows = await db.query(
      'folders',
      where:
          'account_id = ? AND is_deleted = 1 AND deleted_by_folder_id = ?',
      whereArgs: [_currentAccountId, folderId],
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return rows.map((r) => CnestFolder.fromMap(r)).toList();
  }

  /// Cascade file count per binned folder entry, one query — the "N items"
  /// chip on the bin's Folders tab.
  Future<Map<String, int>> getCascadeBinnedCounts() async {
    final db = await database;
    if (_currentAccountId == null) return {};
    final rows = await db.rawQuery(
        'SELECT deleted_by_folder_id AS cause, COUNT(*) AS n FROM files '
        'WHERE account_id = ? AND is_deleted = 1 AND '
        'deleted_by_folder_id IS NOT NULL GROUP BY deleted_by_folder_id',
        [_currentAccountId]);
    return {
      for (final r in rows) r['cause'] as String: r['n'] as int,
    };
  }

  /// Ancestor chain of [folderId], root-first, ENDING with the folder
  /// itself — deleted ancestors included (the bin greys them). Cycle-capped
  /// defensively; materialized live trees are acyclic by invariant.
  Future<List<CnestFolder>> getFolderPathSegments(String folderId) async {
    final db = await database;
    final chain = <CnestFolder>[];
    final seen = <String>{};
    String? cursor = folderId;
    while (cursor != null && seen.add(cursor)) {
      final rows = await db.query('folders',
          where: 'id = ?', whereArgs: [cursor], limit: 1);
      if (rows.isEmpty) break;
      final folder = CnestFolder.fromMap(rows.first);
      chain.insert(0, folder);
      cursor = folder.parentId;
    }
    return chain;
  }

  /// Bin search: EVERY binned file matching [query] — cascade-binned ones
  /// included (that's the point: finding a photo that vanished inside a
  /// deleted folder), LIKE-escaped.
  Future<List<CnestFile>> searchDeletedFiles(String query) async {
    final db = await database;
    if (_currentAccountId == null || query.trim().isEmpty) return [];
    final escaped = query
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final maps = await db.query(
      'files',
      where: 'is_deleted = 1 AND account_id = ? AND '
          "filename LIKE ? ESCAPE '\\'",
      whereArgs: [_currentAccountId, '%$escaped%'],
      orderBy: 'deleted_at DESC',
      limit: 100,
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
    await SyncCoordinator().record(SyncOpKind.restoreFile, id);
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
      // Cascade-binned files (deleted_by_folder_id set) are swept through
      // their FOLDER's bin entry, not individually — one user action, one
      // bin entry, one expiry. The NOT IN clause keeps orphans sweepable:
      // a file whose cause folder row is gone (interrupted purge batch)
      // falls back to individual expiry.
      where: 'is_deleted = 1 AND account_id = ? AND deleted_at IS NOT NULL '
          'AND deleted_at <= ? AND (deleted_by_folder_id IS NULL OR '
          'deleted_by_folder_id NOT IN (SELECT id FROM folders))',
      whereArgs: [_currentAccountId, cutoff],
    );
    return rows.map((r) => r['id'] as String).toList();
  }

  // -----------------------------------------------------------------------
  // Folders — the virtual tree (Model A)
  // -----------------------------------------------------------------------
  //
  // The folders table is a PURE materialized view of the op-log: every
  // mutation below only records an op — SyncEngine.recordLocalOp
  // immediately re-materializes (applyMergedState) and fires
  // notifyFilesChanged, so the local UI updates in the same call without a
  // second writer existing anywhere. Concurrency (cycles, cascade vs
  // individual deletes, restore races) is resolved deterministically at
  // replay; the only guard here is the local move-into-own-subtree check,
  // which exists for immediate UX feedback, not correctness.

  /// Creates a folder and returns its id (null when signed out).
  ///
  /// [id] lets the auto-sync system-folder path mint DETERMINISTIC ids
  /// (see SystemFolders) so every device converges on one folder; user
  /// folders always take the default UUIDv4.
  Future<String?> createFolder(String name,
      {String? parentId, String? id}) async {
    if (_currentAccountId == null) return null;
    final folderId = id ?? const Uuid().v4();
    await SyncCoordinator().record(SyncOpKind.createFolder, folderId,
        name: name, folderId: parentId);
    return folderId;
  }

  /// Single folder row by id, INCLUDING deleted ones — the auto-sync
  /// placement path must see a binned system folder to respect its deletion
  /// rather than resurrect it.
  Future<CnestFolder?> getFolderById(String id) async {
    final db = await database;
    if (_currentAccountId == null) return null;
    final rows = await db.query('folders',
        where: 'account_id = ? AND id = ?',
        whereArgs: [_currentAccountId, id],
        limit: 1);
    if (rows.isEmpty) return null;
    return CnestFolder.fromMap(rows.first);
  }

  /// Whether a purgeFolder op for [id] exists anywhere in the log. Purge is
  /// terminal — replay's create-guard drops any later createFolder for the
  /// same id — so the auto-sync ensure path must stop re-minting a purged
  /// system folder or it would churn a dead op into the log every run.
  Future<bool> isFolderPurged(String id) async {
    final db = await database;
    if (_currentAccountId == null) return false;
    final rows = await db.query('sync_ops',
        columns: ['op_key'],
        where: "account_id = ? AND kind = 'purgeFolder' AND target_id = ?",
        whereArgs: [_currentAccountId, id],
        limit: 1);
    return rows.isNotEmpty;
  }

  Future<void> renameFolder(String id, String newName) =>
      SyncCoordinator().record(SyncOpKind.renameFolder, id, name: newName);

  /// Hides/unhides [id] from the specialized views (typed tabs, gallery,
  /// albums, stories, pickers) with subtree effect. Synced — the bool
  /// payload deliberately rides the generic `favorite` op field (see the
  /// [SyncOpKind.setFolderHidden] doc for why no new wire field exists).
  Future<void> setFolderHidden(String id, bool hidden) =>
      SyncCoordinator().record(SyncOpKind.setFolderHidden, id,
          favorite: hidden);

  /// Reparents [id] under [newParentId] (null = root). Returns false —
  /// recording nothing — when the destination is the folder itself or one
  /// of its descendants (the same rule replay enforces globally).
  Future<bool> moveFolder(String id, String? newParentId) async {
    if (newParentId != null) {
      var cursor = newParentId;
      final hops = <String>{};
      while (true) {
        if (cursor == id) return false;
        if (!hops.add(cursor)) break; // defensive: corrupt local chain
        final rows = await (await database).query('folders',
            columns: ['parent_id'],
            where: 'id = ? AND is_deleted = 0',
            whereArgs: [cursor],
            limit: 1);
        final parent = rows.isEmpty ? null : rows.first['parent_id'] as String?;
        if (parent == null) break;
        cursor = parent;
      }
    }
    await SyncCoordinator()
        .record(SyncOpKind.moveFolder, id, folderId: newParentId);
    return true;
  }

  /// Soft-deletes the folder: the subtree and every live file inside it go
  /// to the Recycle Bin as ONE folder entry (cascade causes stamped by
  /// replay).
  Future<void> deleteFolder(String id) =>
      SyncCoordinator().record(SyncOpKind.deleteFolder, id);

  /// Restores a binned folder as a unit: the folder plus exactly the items
  /// its own delete cascade binned. Items deleted individually stay in the
  /// bin (Model A).
  Future<void> restoreFolder(String id) =>
      SyncCoordinator().record(SyncOpKind.restoreFolder, id);

  /// Moves a file into [folderId] (null = root). The row is updated
  /// locally for instant UI, then the op re-materializes the same value.
  Future<void> moveFileToFolder(String fileId, String? folderId) async {
    final db = await database;
    await db.update('files', {'folder_id': folderId},
        where: 'id = ?', whereArgs: [fileId]);
    await SyncCoordinator()
        .record(SyncOpKind.moveFile, fileId, folderId: folderId);
    notifyListeners();
  }

  /// Live folders under [parentId] (null = root), name-ordered.
  Future<List<CnestFolder>> getFolders({String? parentId}) async {
    final db = await database;
    if (_currentAccountId == null) return [];
    final rows = await db.query(
      'folders',
      where: parentId == null
          ? 'account_id = ? AND is_deleted = 0 AND parent_id IS NULL'
          : 'account_id = ? AND is_deleted = 0 AND parent_id = ?',
      whereArgs:
          parentId == null ? [_currentAccountId] : [_currentAccountId, parentId],
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return rows.map((r) => CnestFolder.fromMap(r)).toList();
  }

  /// Live files directly inside [folderId] (null = root), newest first.
  Future<List<CnestFile>> getFilesInFolder(String? folderId) async {
    final db = await database;
    if (_currentAccountId == null) return [];
    final rows = await db.query(
      'files',
      where: folderId == null
          ? 'account_id = ? AND is_deleted = 0 AND folder_id IS NULL'
          : 'account_id = ? AND is_deleted = 0 AND folder_id = ?',
      whereArgs:
          folderId == null ? [_currentAccountId] : [_currentAccountId, folderId],
      orderBy: 'created_at DESC',
    );
    return rows.map((r) => CnestFile.fromMap(r)).toList();
  }

  /// Direct live files + direct live subfolders per live folder id — the
  /// "N items" chip. A folder IS an item (Windows/pCloud semantics): a
  /// folder holding only a subfolder must not read "0 items".
  Future<Map<String, int>> getFolderItemCounts() async {
    final db = await database;
    if (_currentAccountId == null) return {};
    final counts = <String, int>{};
    final fileRows = await db.rawQuery(
        'SELECT folder_id, COUNT(*) AS n FROM files '
        'WHERE account_id = ? AND is_deleted = 0 AND folder_id IS NOT NULL '
        'GROUP BY folder_id',
        [_currentAccountId]);
    for (final r in fileRows) {
      counts[r['folder_id'] as String] = r['n'] as int;
    }
    final folderRows = await db.rawQuery(
        'SELECT parent_id, COUNT(*) AS n FROM folders '
        'WHERE account_id = ? AND is_deleted = 0 AND parent_id IS NOT NULL '
        'GROUP BY parent_id',
        [_currentAccountId]);
    for (final r in folderRows) {
      final id = r['parent_id'] as String;
      counts[id] = (counts[id] ?? 0) + (r['n'] as int);
    }
    return counts;
  }

  /// Live subtree totals for [folderId]: descendant folders and files
  /// anywhere in the subtree — what a cascade delete will actually bin.
  /// The folder list is small; the subtree expands in Dart.
  Future<({int folders, int files})> getFolderSubtreeCounts(
      String folderId) async {
    final db = await database;
    if (_currentAccountId == null) return (folders: 0, files: 0);
    final rows = await db.query('folders',
        columns: ['id', 'parent_id'],
        where: 'account_id = ? AND is_deleted = 0',
        whereArgs: [_currentAccountId]);
    final children = <String?, List<String>>{};
    for (final r in rows) {
      children
          .putIfAbsent(r['parent_id'] as String?, () => [])
          .add(r['id'] as String);
    }
    final subtree = <String>{folderId};
    final queue = [folderId];
    while (queue.isNotEmpty) {
      for (final child in children[queue.removeLast()] ?? const <String>[]) {
        if (subtree.add(child)) queue.add(child);
      }
    }
    final placeholders = List.filled(subtree.length, '?').join(',');
    final fileCount = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT COUNT(*) FROM files WHERE account_id = ? '
            'AND is_deleted = 0 AND folder_id IN ($placeholders)',
            [_currentAccountId, ...subtree])) ??
        0;
    return (folders: subtree.length - 1, files: fileCount);
  }

  /// Binned TOP-LEVEL folder entries (deleted directly, not by a cascade) —
  /// the Recycle Bin's Folders tab. Most recently trashed first.
  Future<List<CnestFolder>> getDeletedFolders() async {
    final db = await database;
    if (_currentAccountId == null) return [];
    final rows = await db.query(
      'folders',
      where: 'account_id = ? AND is_deleted = 1 AND '
          'deleted_by_folder_id IS NULL',
      whereArgs: [_currentAccountId],
      orderBy: 'deleted_at DESC',
    );
    return rows.map((r) => CnestFolder.fromMap(r)).toList();
  }

  /// Ids of binned files a deleteFolder([folderId]) cascade binned — the
  /// contents a folder purge must permanently delete.
  Future<List<String>> getCascadeBinnedFileIds(String folderId) async {
    final db = await database;
    if (_currentAccountId == null) return [];
    final rows = await db.query(
      'files',
      columns: ['id'],
      where:
          'account_id = ? AND is_deleted = 1 AND deleted_by_folder_id = ?',
      whereArgs: [_currentAccountId, folderId],
    );
    return rows.map((r) => r['id'] as String).toList();
  }

  /// Records the terminal purgeFolder ops for [id] and every cascade-binned
  /// descendant folder. Contents must already be purged file-by-file
  /// (purgeFile ops via [permanentlyDeleteFile]) — folder purge NEVER
  /// derives a file set, so the condemned-blob sweep, reconcile's tombstone
  /// guard, and Vault Health stay tree-agnostic.
  Future<void> purgeFolderEntity(String id) async {
    final db = await database;
    final descendants = await db.query(
      'folders',
      columns: ['id'],
      where: 'account_id = ? AND deleted_by_folder_id = ?',
      whereArgs: [_currentAccountId, id],
    );
    for (final row in descendants) {
      await SyncCoordinator()
          .record(SyncOpKind.purgeFolder, row['id'] as String);
    }
    await SyncCoordinator().record(SyncOpKind.purgeFolder, id);
  }

  /// Binned folder entries whose 30-day TTL has lapsed — the folder-shaped
  /// half of the bin sweep.
  Future<List<String>> getExpiredFolderIds({
    Duration ttl = const Duration(days: 30),
  }) async {
    final db = await database;
    if (_currentAccountId == null) return [];
    final cutoff = DateTime.now().subtract(ttl).millisecondsSinceEpoch;
    final rows = await db.query(
      'folders',
      columns: ['id'],
      where: 'account_id = ? AND is_deleted = 1 AND '
          'deleted_by_folder_id IS NULL AND deleted_at IS NOT NULL AND '
          'deleted_at <= ?',
      whereArgs: [_currentAccountId, cutoff],
    );
    return rows.map((r) => r['id'] as String).toList();
  }

  /// Filenames of the current account's rows — live AND recycle-bin — that
  /// start with [stemPrefix]: the collision-candidate set for
  /// duplicate-rename. Binned rows count because they're restorable;
  /// excluding them let "upload same file again → restore the binned one"
  /// end with two identically-named files. Only a purge frees a name.
  /// LIKE-escaped so stems containing % or _ don't over-match.
  Future<Set<String>> getActiveFilenames({required String stemPrefix}) async {
    final db = await database;
    if (_currentAccountId == null) return {};
    final escaped = stemPrefix
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final rows = await db.query(
      'files',
      columns: ['filename'],
      // Deliberately NO is_deleted filter: a recycle-bin row is restorable,
      // so its name is still taken — excluding it let a re-upload claim the
      // same name and a later restore produce two identically-named files.
      // Only a purge (hard delete) frees a name.
      where: "account_id = ? AND filename LIKE ? ESCAPE '\\'",
      whereArgs: [_currentAccountId, '$escaped%'],
    );
    return rows.map((r) => r['filename'] as String).toSet();
  }

  /// True when a LIVE, fully-uploaded row already holds these exact
  /// plaintext bytes — the batch-upload duplicate pre-check. Binned rows
  /// don't count (restoring one shouldn't have blocked a re-upload).
  Future<bool> hasActiveContentHash(String hash) async {
    final db = await database;
    if (_currentAccountId == null) return false;
    final rows = await db.query(
      'files',
      columns: ['id'],
      where: 'account_id = ? AND content_hash = ? AND is_deleted = 0 '
          'AND cloud_id IS NOT NULL',
      whereArgs: [_currentAccountId, hash],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<CnestFile?> getFileById(String id) async {
    final db = await database;
    final rows =
        await db.query('files', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : CnestFile.fromMap(rows.first);
  }

  /// Current-account rows owning the given cache artifacts that are
  /// MediaStore-bound (asset_id set) — the candidate set for the
  /// leftover-reclaim sweep (see
  /// CacheManagerService.reclaimMediaStoreServedLeftovers).
  Future<List<CnestFile>> getMediaStoreBoundFiles({
    required Set<String> cloudIds,
    required Set<String> fileIds,
  }) async {
    if (_currentAccountId == null) return [];
    if (cloudIds.isEmpty && fileIds.isEmpty) return [];
    final db = await database;
    final clauses = <String>[];
    if (cloudIds.isNotEmpty) {
      clauses.add(
          'cloud_id IN (${List.filled(cloudIds.length, '?').join(',')})');
    }
    if (fileIds.isNotEmpty) {
      clauses.add('id IN (${List.filled(fileIds.length, '?').join(',')})');
    }
    final rows = await db.query(
      'files',
      where:
          'account_id = ? AND asset_id IS NOT NULL AND (${clauses.join(' OR ')})',
      whereArgs: [_currentAccountId, ...cloudIds, ...fileIds],
    );
    return rows.map(CnestFile.fromMap).toList();
  }

  Future<void> setFavorite(String id, bool favorite) async {
    final db = await database;
    await db.update(
      'files',
      {'is_favorite': favorite ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
    await SyncCoordinator()
        .record(SyncOpKind.setFavorite, id, favorite: favorite);
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
    await SyncCoordinator()
        .record(SyncOpKind.renameFile, id, name: newFilename);
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
      where: 'is_favorite = 1 AND account_id = ? AND is_deleted = 0'
          '${hiddenExclusion()}',
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

  /// Index the auto-sync scan uses to decide "is this gallery asset already
  /// in the vault?". Three sets with distinct semantics:
  ///
  ///  * [uploadedKeys] — `filename|size` of rows whose upload COMPLETED.
  ///    Only these hide an asset permanently: a pending phantom row must
  ///    never block its own asset from being retried (the ghost-photo bug).
  ///  * [knownAssetIds] — MediaStore asset ids of ALL non-deleted rows,
  ///    uploaded or pending. Asset id is stable identity, so it still
  ///    matches after a duplicate-rename gave the row a "(1)" filename.
  ///  * [inFlightKeys] — `filename|size` of pending rows whose last upload
  ///    attempt is fresher than [inFlightWindow]: an upload racing right
  ///    now must still dedup, or the scan would double-upload it.
  Future<AutoSyncDedupIndex> getAutoSyncDedupIndex({
    Duration inFlightWindow = const Duration(minutes: 15),
  }) async {
    final db = await database;
    if (_currentAccountId == null) return const AutoSyncDedupIndex.empty();
    final rows = await db.query(
      'files',
      columns: [
        'filename',
        'size_bytes',
        'is_uploaded',
        'asset_id',
        'upload_started_at',
      ],
      // Recycle-bin rows are included on purpose: a binned file is still
      // THIS gallery asset's vault copy — treating it as unknown would make
      // auto-sync re-upload the original as a full duplicate blob while the
      // binned twin waits to be restored.
      where: 'account_id = ? AND type IN (?, ?)',
      whereArgs: [
        _currentAccountId,
        CnestFileType.image.index,
        CnestFileType.document.index,
      ],
    );
    final uploadedKeys = <String>{};
    final knownAssetIds = <String>{};
    final inFlightKeys = <String>{};
    final freshFloor = DateTime.now()
        .subtract(inFlightWindow)
        .millisecondsSinceEpoch;
    for (final r in rows) {
      final key = '${r['filename']}|${r['size_bytes'] ?? 0}';
      final assetId = r['asset_id'] as String?;
      if (assetId != null) knownAssetIds.add(assetId);
      if (r['is_uploaded'] == 1) {
        uploadedKeys.add(key);
        continue;
      }
      final attempt = r['upload_started_at'] as int?;
      if (attempt != null && attempt >= freshFloor) inFlightKeys.add(key);
    }
    return AutoSyncDedupIndex(
      uploadedKeys: uploadedKeys,
      knownAssetIds: knownAssetIds,
      inFlightKeys: inFlightKeys,
    );
  }

  /// SQL fragment excluding files that live under a view-hidden folder
  /// subtree (folders.hidden_effective, materialized by applyMergedState).
  /// SPECIALIZED views only — typed tabs, gallery, stories, albums, covers,
  /// pickers. NEVER the Files browser and NEVER the Recycle Bin: the tree
  /// itself and the bin always show everything.
  ///
  /// The subquery is correlated on account: system-folder ids are
  /// deterministic and account-AGNOSTIC (SystemFolders), so with two linked
  /// accounts one account's hidden Phone Backup row would otherwise filter
  /// the OTHER account's files out of its own gallery.
  static String hiddenExclusion([String prefix = '']) {
    final outer = prefix.isEmpty ? 'files.' : prefix;
    return ' AND (${prefix}folder_id IS NULL OR ${prefix}folder_id NOT IN '
        '(SELECT id FROM folders WHERE hidden_effective = 1 '
        'AND folders.account_id = ${outer}account_id))';
  }

  /// [includeHidden] is for MACHINERY callers only (migration dedup, the
  /// "is the vault empty?" check) — anything user-facing must keep the
  /// default so hidden folders stay hidden.
  Future<List<CnestFile>> getFilesByType(CnestFileType type,
      {bool includeHidden = false}) async {
    final db = await database;
    if (_currentAccountId == null) return [];

    // One-tree model: typed views cover the whole corpus — folder placement
    // is invisible here; only a hidden ancestor excludes a file.
    final List<Map<String, dynamic>> maps = await db.query(
      'files',
      where: 'type = ? AND account_id = ? AND is_deleted = 0'
          '${includeHidden ? '' : hiddenExclusion()}',
      whereArgs: [type.index, _currentAccountId],
      orderBy: 'created_at DESC',
    );
    return List.generate(maps.length, (i) => CnestFile.fromMap(maps[i]));
  }

  // --- SYNC LOGIC (MAP ADAPTED) ---

  /// The provider type of a REGISTERED account by id — never the active
  /// account's, which can differ when a sync cycle pinned to [accountId]
  /// finishes after the user switched accounts.
  int _providerTypeFor(String accountId) {
    for (final a in AccountRegistry().accounts) {
      if (a.id == accountId) return a.providerType;
    }
    return AccountRegistry().activeAccount?.providerType ?? 0;
  }

  /// Reconciles [cloudFiles] against the rows of ONE account. [accountId]
  /// pins which one; callers running a long sync cycle MUST pass the id
  /// captured at cycle start — reading the current account here would prune
  /// the newly active account's rows against another account's listing when
  /// the user switches mid-cycle. Defaults to the current account for
  /// short, synchronous-ish flows (connect screen).
  /// File ids with a `purgeFile` tombstone in the op log — permanently
  /// deleted, forever. Purge is terminal by design (see op_replay.dart), so
  /// this set only ever grows, and anything in it must NEVER be re-adopted
  /// from a cloud listing: a blob that outlives its purge (the "Delete
  /// forever" cloud call failed, silently) is condemned, not new.
  Future<Set<String>> getPurgedFileIds({String? accountId}) async {
    final acct = accountId ?? _currentAccountId;
    if (acct == null) return {};
    final db = await database;
    final rows = await db.query(
      'sync_ops',
      columns: ['target_id'],
      where: "kind = 'purgeFile' AND account_id = ?",
      whereArgs: [acct],
    );
    return rows.map((r) => r['target_id'] as String).toSet();
  }

  /// The local file id that owns a vault blob: `<uuid>.cnest` and
  /// `<uuid>_thumb.cnest` both belong to `<uuid>`; legacy names (no .cnest
  /// suffix) are owned by their own cloud id.
  static String blobOwnerId(String name, String cloudId) {
    if (name.endsWith('_thumb.cnest')) {
      return name.substring(0, name.length - '_thumb.cnest'.length);
    }
    if (name.endsWith('.cnest')) {
      return name.substring(0, name.length - '.cnest'.length);
    }
    return cloudId;
  }

  Future<void> reconcile(
    List<Map<String, dynamic>> cloudFiles, {
    String? accountId,
  }) async {
    final acct = accountId ?? _currentAccountId;
    if (acct == null) return;
    final providerType = _providerTypeFor(acct);
    final purged = await getPurgedFileIds(accountId: acct);

    final db = await database;
    final batch = db.batch();

    final cloudIds = cloudFiles.map((f) => f['id'] as String).toSet();
    final localRows = await db.query(
      'files',
      columns: ['id', 'cloud_id'],
      where: 'is_uploaded = 1 AND account_id = ?',
      whereArgs: [acct]
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
      whereArgs: [acct]
    );
    final knownCloudIds = knownCloudIdsRows.map((r) => r['cloud_id']).toSet();

    final mainFiles = <Map<String, dynamic>>[];
    final thumbnailFiles = <Map<String, dynamic>>[];

    // Exclude the DB backup file from reconciliation
    cloudFiles.removeWhere((f) => f['name'] == 'ciphernest_db_backup.cnest');

    for (var file in cloudFiles) {
      final id = file['id'];
      final name = file['name'] as String? ?? '';

      // A blob owned by a purged file id is condemned — the user hit
      // "Delete forever" but the cloud delete didn't land. Adopting it here
      // is exactly how permanently deleted photos used to resurrect every
      // sync cycle (the op-log purge removed the row, this pass re-created
      // it). Skip both the main blob and its thumb; the sync cycle's
      // condemned-blob sweep retries the actual cloud deletion.
      if (id != null && purged.contains(blobOwnerId(name, id as String))) {
        continue;
      }

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
      } else if (file['size'] is String) {
        size = int.tryParse(file['size']) ?? 0;
      }

      insertBatch.insert(
        'files',
        {
          'id': localId,
          'cloud_id': file['id'],
          'provider': providerType,
          'account_id': acct,
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

    // Join op-created rows to their blobs: a file that arrived via the
    // sync log exists locally with cloud_id NULL until this pass matches
    // the blob by its uuid stem. Only NULL cloud_ids are touched — the
    // op-log never owns blob bookkeeping and vice versa.
    for (var file in mainFiles) {
      final name = file['name'] as String? ?? '';
      if (!name.endsWith('.cnest')) continue;
      linkBatch.update(
        'files',
        {
          'cloud_id': file['id'],
          'provider': providerType,
        },
        where: 'id = ? AND cloud_id IS NULL',
        whereArgs: [name.replaceAll('.cnest', '')],
      );
    }

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

  /// Cloud-id → local-id map for one account. [accountId] pins the account
  /// for long sync cycles (see [reconcile]); defaults to the current one.
  Future<Map<String, String>> getCloudToLocalIdMap({String? accountId}) async {
    final db = await database;
    final acct = accountId ?? _currentAccountId;
    if (acct == null) return {};
    final rows = await db.query(
      'files',
      columns: ['id', 'cloud_id', 'thumbnail_cloud_id'],
      where: 'is_uploaded = 1 AND account_id = ? AND is_deleted = 0',
      whereArgs: [acct],
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
              WHERE af.album_id = a.id AND f.is_deleted = 0
              ${hiddenExclusion('f.')})
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
      ${hiddenExclusion('f.')}
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
          where: 'id = ? AND is_deleted = 0${hiddenExclusion()}',
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
      ${hiddenExclusion('f.')}
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
      'SELECT * FROM files WHERE $where AND account_id = ?'
      '${hiddenExclusion()} ORDER BY created_at DESC$limitClause',
      [_currentAccountId],
    );
    return maps.map((m) => CnestFile.fromMap(m)).toList();
  }

  Future<int> _smartAlbumCount(Database db, String query) async {
    final where = _smartAlbumWhere(query);
    if (where == null) return 0;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM files WHERE $where AND account_id = ?'
      '${hiddenExclusion()}',
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
          'AND created_at BETWEEN ? AND ?${hiddenExclusion()}',
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