/// The production sync engine: op recording, segment push/pull, and the
/// materialized-view writer.
///
/// ## THE STRUCTURAL RULE — SQLite is a view, never a source
///
/// Ops enter the log in exactly ONE place: [recordLocalOp], whose inputs
/// are the parameters of a user action happening RIGHT NOW. It does not
/// read the files table; it has no way to accept a row. There is no other
/// INSERT into `sync_ops` with `pending = 1` anywhere in the codebase, and
/// [applyMergedState] — the only writer of op-derived columns in `files` —
/// flows strictly log -> rows. A local row that has no op behind it can
/// therefore never re-enter the log, which is what makes resurrection of
/// deleted files STRUCTURALLY impossible rather than statistically
/// unlikely: after a tombstone is merged, nothing exists that could
/// re-create the file except a human pressing Restore (which records a new
/// restore op, exactly as it should).
///
/// Cloud IO is injected via [SyncTransport] so the engine is fully testable
/// against a real SQLite database with a fake cloud.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../../src/models/file_model.dart';
import '../database_service.dart';
import '../device_identity_service.dart';
import '../system_folders.dart';
import 'compaction.dart';
import 'hlc.dart';
import 'vault_health_service.dart';
import 'op_replay.dart';
import 'segment_codec.dart';
import 'sync_op.dart';

/// Cloud IO surface the engine needs. Production: [CloudSyncTransport]
/// (backed by CloudService); tests: an in-memory fake.
abstract class SyncTransport {
  Future<List<Map<String, dynamic>>> listLogObjects();
  Future<Uint8List> downloadObject(String cloudId);
  Future<void> uploadLogObject({
    required String name,
    required Uint8List bytes,
  });

  /// Deletes a folded log object (compaction only — nothing else in the
  /// engine ever deletes cloud state).
  Future<void> deleteObject(String cloudId);
}

/// An edit-vs-delete conflict surfaced to the user after a sync.
class SyncConflict {
  final String fileId;
  final String fileName;
  final String deleterDeviceId;

  /// True if permanently purged (gone), false if soft-deleted (in the bin).
  final bool purged;

  /// True when the conflicted item is a FOLDER (my rename/move vs a foreign
  /// deleteFolder) — the notice copy differs.
  final bool isFolder;
  const SyncConflict({
    required this.fileId,
    required this.fileName,
    required this.deleterDeviceId,
    required this.purged,
    this.isFolder = false,
  });
}

/// A moveFolder of THIS device that the Kleppmann cycle rule skipped: the
/// user's move silently didn't happen, so they get told once.
class UndoneFolderMove {
  final String opKey;
  final String folderName;

  /// The device whose conflicting move won, when attributable.
  final String? otherDeviceId;
  const UndoneFolderMove({
    required this.opKey,
    required this.folderName,
    this.otherDeviceId,
  });
}

/// A semantic user action, as [recordLocalOp] accepts it. Deliberately NOT
/// constructible from a database row — it has no fromMap, and every field
/// is what the user just did, not what storage contains.
class LocalSyncAction {
  final SyncOpKind kind;
  final String targetId;
  final String? name;
  final String? folderId;
  final bool? favorite;
  final String? hash;
  final int? size;
  final int? captured;

  const LocalSyncAction({
    required this.kind,
    required this.targetId,
    this.name,
    this.folderId,
    this.favorite,
    this.hash,
    this.size,
    this.captured,
  });
}

class SyncEngine {
  final SyncTransport transport;
  final String accountId;
  final Future<Database> Function() _db;
  final Future<String> Function() _deviceId;

  SyncEngine({
    required this.transport,
    required this.accountId,
    Future<Database> Function()? database,
    Future<String> Function()? deviceId,
    int Function()? wallClock,
  })  : _db = database ?? (() => DatabaseService().database),
        _deviceId = deviceId ?? (() => DeviceIdentityService().deviceId()),
        _wallClock =
            wallClock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _wallClock;

  // ---------------------------------------------------------------------
  // OP CREATION — the only path into the log
  // ---------------------------------------------------------------------

  /// Records a user action as a pending op. THE ONLY writer of new ops.
  ///
  /// Enforcement of "no DB row is ever retro-promoted into an op": this
  /// function's input is a [LocalSyncAction] — the parameters of an action
  /// the user is performing at this moment. It performs NO reads of the
  /// files table. Nothing else in the codebase inserts into `sync_ops`
  /// with `pending = 1` (test-pinned in sync_engine_db_test.dart), and
  /// [fullResync] explicitly refuses to mint ops from surviving rows.
  Future<SyncOp> recordLocalOp(LocalSyncAction action) async {
    assert(action.kind != SyncOpKind.unknown,
        'the unknown sentinel is a decode artifact, never a user action');
    final db = await _db();
    final deviceId = await _deviceId();
    return db.transaction((txn) async {
      final state = await _loadState(txn);
      final hlc = Hlc.send(
          Hlc(state.hlcWall, state.hlcCounter), _wallClock());
      final op = SyncOp(
        kind: action.kind,
        deviceId: deviceId,
        seq: state.nextSeq,
        hlc: hlc,
        targetId: action.targetId,
        name: action.name,
        folderId: action.folderId,
        favorite: action.favorite,
        hash: action.hash,
        size: action.size,
        captured: action.captured,
      );
      await txn.insert('sync_ops', _opToRow(op, pending: true),
          conflictAlgorithm: ConflictAlgorithm.ignore);
      await _saveState(
        txn,
        hlcWall: hlc.wallMs,
        hlcCounter: hlc.counter,
        nextSeq: state.nextSeq + 1,
        nextSegment: state.nextSegment,
        lastPullWall: state.lastPullWall,
      );
      return op;
    }).then((op) async {
      // Log -> row, immediately: the user's own action must be visible in
      // the view without waiting for a sync cycle. Same one-directional
      // writer as always — the op came first, the row follows it.
      await applyMergedState();
      return op;
    });
  }

  // ---------------------------------------------------------------------
  // SYNC CYCLE — push pending, pull unseen, re-materialize
  // ---------------------------------------------------------------------

  /// Pushes pending ops as sealed segments, pulls and merges unseen
  /// segments, then re-materializes the files table. [pullAndMerge] (and
  /// therefore decrypting segments) requires the unlocked vault; pushing
  /// does not — call [pushPending] alone from locked/background contexts.
  ///
  /// No staleness gate is needed: tombstones are eternal (compaction never
  /// GCs), so a straggler create can never out-live its tombstone and
  /// resurrect. A device offline for years simply pulls and converges.
  Future<void> syncCycle() async {
    await pushPending();
    await pullAndMerge();
    await applyMergedState();
  }

  /// Uploads pending ops as an immutable segment. Public-key-only crypto —
  /// works while the vault is locked (encrypt-while-locked survives).
  ///
  /// Crash ordering: the segment NAME is fixed before any IO, and the
  /// upload is verified/skipped on retry, so every crash prefix leaves
  /// either "segment absent + ops still pending" or "segment present +
  /// pending clearable". Ops are marked non-pending only after the segment
  /// is durably in the cloud.
  Future<void> pushPending() async {
    final db = await _db();
    final deviceId = await _deviceId();

    while (true) {
      final pendingRows = await db.query(
        'sync_ops',
        where: 'account_id = ? AND pending = 1 AND device_id = ?',
        whereArgs: [accountId, deviceId],
        orderBy: 'seq ASC',
      );
      if (pendingRows.isEmpty) return;
      final ops = pendingRows.map(_rowToOp).toList();

      final state = await _loadState(db);
      final segName = SegmentCodec.segmentName(deviceId, state.nextSegment);

      // Did a previous crashed attempt already land this segment?
      final existing = await transport.listLogObjects();
      final alreadyUploaded =
          existing.any((o) => o['name'] == segName);

      if (!alreadyUploaded) {
        final sealed = await SegmentCodec.seal(ops);
        if (sealed == null) {
          debugPrint('SyncEngine: no vault public key — push deferred');
          return;
        }
        await transport.uploadLogObject(name: segName, bytes: sealed);
      }

      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final op in ops) {
          batch.update('sync_ops', {'pending': 0},
              where: 'op_key = ?', whereArgs: [op.opKey]);
        }
        batch.insert(
            'sync_seen_segments', {'account_id': accountId, 'name': segName},
            conflictAlgorithm: ConflictAlgorithm.ignore);
        await batch.commit(noResult: true);
        final s = await _loadState(txn);
        await _saveState(txn,
            hlcWall: s.hlcWall,
            hlcCounter: s.hlcCounter,
            nextSeq: s.nextSeq,
            nextSegment: s.nextSegment + 1,
            lastPullWall: s.lastPullWall);
      });
    }
  }

  /// Downloads unseen segments, merges their ops, re-materializes.
  /// Requires the unlocked vault (segment decryption). Unreadable segments
  /// are counted and left unseen — retried next cycle, surfaced via the
  /// return value for Vault Health.
  Future<int> pullAndMerge() async {
    final db = await _db();
    final objects = await transport.listLogObjects();
    final seenRows = await db.query('sync_seen_segments',
        columns: ['name'],
        where: 'account_id = ?',
        whereArgs: [accountId]);
    final seen = seenRows.map((r) => r['name'] as String).toSet();

    var unreadable = 0;
    var merged = 0;
    for (final obj in objects) {
      final name = obj['name'] as String? ?? '';
      if (seen.contains(name)) continue;
      final isSegment = SegmentCodec.parseName(name) != null;
      final isSnapshot = SegmentCodec.parseSnapshotName(name) != null;
      if (!isSegment && !isSnapshot) continue;
      final bytes = await transport.downloadObject(obj['id'] as String);
      // Merge-everything is sound: ops dedupe by key, and GC only ever
      // removes whole-file op-sets, so overlapping snapshots/segments can
      // only re-add consistent pairs.
      final ops = isSnapshot
          ? (await SegmentCodec.tryOpenSnapshot(bytes))?.ops
          : await SegmentCodec.tryOpen(bytes);
      if (ops == null) {
        unreadable++;
        continue; // NOT marked seen — retried, never silently absorbed
      }
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final op in ops) {
          batch.insert('sync_ops', _opToRow(op, pending: false),
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        batch.insert(
            'sync_seen_segments', {'account_id': accountId, 'name': name},
            conflictAlgorithm: ConflictAlgorithm.ignore);
        await batch.commit(noResult: true);

        // HLC receive: local sends must order after everything seen.
        var s = await _loadState(txn);
        var local = Hlc(s.hlcWall, s.hlcCounter);
        for (final op in ops) {
          local = Hlc.receive(local, op.hlc, _wallClock());
        }
        await _saveState(txn,
            hlcWall: local.wallMs,
            hlcCounter: local.counter,
            nextSeq: s.nextSeq,
            nextSegment: s.nextSegment,
            lastPullWall: s.lastPullWall);
      });
      merged += ops.length;
    }

    // Pull completed: stamp the staleness watermark.
    await db.transaction((txn) async {
      final s = await _loadState(txn);
      await _saveState(txn,
          hlcWall: s.hlcWall,
          hlcCounter: s.hlcCounter,
          nextSeq: s.nextSeq,
          nextSegment: s.nextSegment,
          lastPullWall: _wallClock());
    });

    // Persist the unreadable count for Vault Health (surfaced in Settings).
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kUnreadableSegmentsPref, unreadable);

    // Clock-skew advisory: if the newest op we've seen carries a wall time
    // far from this device's clock, some device's clock is wrong. This is
    // benign for correctness (HLC handles it — see hlc.dart) but worth
    // telling the user, since a very wrong clock can make that device win
    // cosmetic edit conflicts until clocks realign.
    final maxRow = await db.rawQuery(
        'SELECT MAX(hlc_wall) AS m FROM sync_ops WHERE account_id = ?',
        [accountId]);
    final newestWall = (maxRow.first['m'] as int?) ?? 0;
    final skewMs = (newestWall - _wallClock()).abs();
    await prefs.setBool(kClockSkewPref,
        newestWall > 0 && skewMs > kClockSkewThresholdMs);

    if (merged > 0 || unreadable > 0) {
      await applyMergedState();
    }
    return unreadable;
  }

  // ---------------------------------------------------------------------
  // COMPACTION (Stage 2e)
  // ---------------------------------------------------------------------

  /// Folds old log objects into one snapshot. Deterministic and safe by
  /// construction:
  ///  * only objects whose PROVIDER upload time is older than the fold
  ///    floor are touched (its only use — never conflict resolution);
  ///  * the snapshot carries the folded ops VERBATIM except whole-file GC
  ///    of long-dead tombstones (see compaction.dart for why);
  ///  * the snapshot is uploaded, DOWNLOADED BACK and verified readable
  ///    before a single folded object is deleted;
  ///  * concurrent compactors write differently-named snapshots whose
  ///    merge is idempotent — nothing is ever overwritten.
  Future<void> compactIfDue() async {
    final db = await _db();
    final deviceId = await _deviceId();
    final objects = await transport.listLogObjects();
    final nowMs = _wallClock();

    final foldable = <Map<String, dynamic>>[];
    for (final obj in objects) {
      final name = obj['name'] as String? ?? '';
      if (SegmentCodec.parseName(name) == null &&
          SegmentCodec.parseSnapshotName(name) == null) {
        continue;
      }
      final uploadedStr = obj['uploaded'] as String?;
      final uploaded =
          uploadedStr == null ? null : DateTime.tryParse(uploadedStr);
      if (uploaded == null) continue; // unknown age: never fold
      if (nowMs - uploaded.millisecondsSinceEpoch <
          Compaction.foldableAgeMs) {
        continue;
      }
      foldable.add(obj);
    }
    if (foldable.length < Compaction.minFoldable) return;

    // Open every foldable object; ANY unreadable one aborts the whole
    // compaction — we never delete what we could not read.
    final foldedNames = <String>[];
    final opsByKey = <String, SyncOp>{};
    for (final obj in foldable) {
      final name = obj['name'] as String;
      final bytes = await transport.downloadObject(obj['id'] as String);
      final ops = SegmentCodec.parseSnapshotName(name) != null
          ? (await SegmentCodec.tryOpenSnapshot(bytes))?.ops
          : await SegmentCodec.tryOpen(bytes);
      if (ops == null) {
        debugPrint('SyncEngine.compact: $name unreadable — aborting');
        return;
      }
      foldedNames.add(name);
      for (final op in ops) {
        opsByKey.putIfAbsent(op.opKey, () => op);
      }
    }

    final snapshotOps = Compaction.snapshotOps(opsByKey.values.toList());

    final state = await _loadState(db);
    final snapName = SegmentCodec.snapshotName(deviceId, state.nextSegment);
    final sealed = await SegmentCodec.sealSnapshot(
        foldedNames: foldedNames, ops: snapshotOps);
    if (sealed == null) return;
    await transport.uploadLogObject(name: snapName, bytes: sealed);

    // Read-back verification before any deletion.
    final listed = await transport.listLogObjects();
    final uploadedObj = listed.where((o) => o['name'] == snapName).toList();
    if (uploadedObj.isEmpty) return;
    final verify = await SegmentCodec.tryOpenSnapshot(
        await transport.downloadObject(uploadedObj.first['id'] as String));
    if (verify == null ||
        verify.ops.length != snapshotOps.length ||
        verify.folded.length != foldedNames.length) {
      debugPrint('SyncEngine.compact: read-back verification failed — '
          'folded objects NOT deleted');
      return;
    }

    for (final obj in foldable) {
      await transport.deleteObject(obj['id'] as String);
    }

    // Local bookkeeping: the snapshot is by-construction merged; folded
    // names stay harmlessly in seen.
    await db.transaction((txn) async {
      final batch = txn.batch();
      batch.insert(
          'sync_seen_segments', {'account_id': accountId, 'name': snapName},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      // CRITICAL: merge the folded ops into our own log. Compaction reads
      // segments from the cloud this device may not have merged yet;
      // folding + deleting them + marking the snapshot seen would otherwise
      // lose those ops from this device forever (property harness seed 9).
      for (final op in snapshotOps) {
        batch.insert('sync_ops', _opToRow(op, pending: false),
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      final s = await _loadState(txn);
      await _saveState(txn,
          hlcWall: s.hlcWall,
          hlcCounter: s.hlcCounter,
          nextSeq: s.nextSeq,
          nextSegment: s.nextSegment + 1,
          lastPullWall: s.lastPullWall);
      await batch.commit(noResult: true);
    });
  }

  // ---------------------------------------------------------------------
  // THE MATERIALIZED-VIEW WRITER
  // ---------------------------------------------------------------------

  /// Re-derives the op-owned columns of `files` from the log. The ONLY
  /// writer of those columns during sync, and strictly one-directional:
  /// log -> rows. It never creates ops, never reads rows to decide what
  /// the log should say, and never touches device-local columns
  /// (cloud_id, thumbnail_cloud_id, local_path, asset_id, is_uploaded,
  /// size_bytes, type, created_at) except when materializing a row this
  /// device has never seen.
  ///
  /// Rows without ops (pre-sync legacy rows, Vault-Health recoveries in
  /// progress) are LEFT ALONE — visible locally, never promoted into the
  /// log, exactly the property that kills resurrection.
  Future<void> applyMergedState() async {
    final db = await _db();
    // pending 0 = synced, 1 = local not-yet-uploaded; both are in the view.
    final opRows = await db.query('sync_ops',
        where: 'account_id = ?', whereArgs: [accountId]);
    if (opRows.isEmpty) return;
    final allOps = opRows.map(_rowToOp).toList();
    final state = replayOps(allOps);

    // Live-or-root normalization at the WRITE boundary (op_replay's header
    // promise): a live item's folder pointer resolves against live folders;
    // binned items keep the RAW pointer (the bin shows original context,
    // and the raw pointer is what lets a child rejoin a restored parent).
    String? liveOrRoot(String? id) => id != null &&
            state.folders.containsKey(id) &&
            !state.folders[id]!.deleted
        ? id
        : null;

    final fileRows = await db.query('files',
        columns: [
          'id',
          'filename',
          'is_favorite',
          'is_deleted',
          'deleted_at',
          'folder_id',
          'deleted_by_folder_id',
          'size_bytes',
          'content_hash',
          'created_at',
        ],
        where: 'account_id = ?',
        whereArgs: [accountId]);
    final existing = {for (final r in fileRows) r['id'] as String: r};

    // Purged files are removed from replay's state, so drop their rows too —
    // this is how a device that only just learned of a peer's permanent
    // deletion converges (the row disappears everywhere).
    final purgedIds = <String>{
      for (final op in allOps)
        if (op.kind == SyncOpKind.purgeFile) op.targetId,
    };
    final batchPurge = db.batch();
    for (final id in purgedIds) {
      if (existing.containsKey(id)) {
        batchPurge.delete('files', where: 'id = ?', whereArgs: [id]);
      }
    }
    await batchPurge.commit(noResult: true);

    final batch = db.batch();
    final nowMs = _wallClock();
    for (final e in state.files.entries) {
      final id = e.key;
      final f = e.value;
      final row = existing[id];
      // ONE derived map, spread into the insert AND diffed into the update —
      // the two paths structurally cannot disagree on an op-owned column
      // (the created_at-divergence bug class, closed by construction).
      //
      // deleted_at comes from replay's EXPLICIT tombstone wall — the HLC
      // wall of whichever op flipped deleted, deleteFolder cascades
      // included. The old per-column scan only knew deleteFile ops, so a
      // cascade-binned file materialized with deleted_at = 0 and the
      // 30-day bin sweep would have purged it instantly.
      final derived = <String, Object?>{
        'filename': f.name,
        'is_favorite': f.favorite ? 1 : 0,
        'is_hidden': f.hidden ? 1 : 0,
        'is_deleted': f.deleted ? 1 : 0,
        'deleted_at': f.deleted ? f.tombstoneWall : null,
        'folder_id': f.deleted ? f.folderId : liveOrRoot(f.folderId),
        'deleted_by_folder_id': f.deletedByFolderId,
      };
      // Every file the log knows is materialized, live or binned. Tombstones
      // are eternal and identical on every device (no GC), so this converges
      // without any age-based "ghost" cutoff. The Recycle Bin screen filters
      // by deleted_at age for DISPLAY — a pure function of the tombstone's
      // own timestamp, so display stays consistent too.
      if (row == null) {
        final create = _createOp(allOps, id);
        batch.insert(
            'files',
            {
              'id': id,
              'cloud_id': null, // reconcile joins the blob by stem later
              'account_id': accountId,
              // Size + hash travel in the createFile op, so a peer shows the
              // right size immediately (fixes the "0 bytes" a synced file
              // showed before reconcile joined the blob) and can dedup by
              // content later.
              'size_bytes': create?.size ?? 0,
              'content_hash': create?.hash,
              // Canonical, device-identical gallery sort key: capture time
              // (shipped in the op) when known, else the create op's HLC wall
              // (also identical on every device). Both S and V therefore
              // materialize the SAME created_at and show the SAME order.
              'created_at': create?.captured ?? _createWall(opRows, id) ?? nowMs,
              'is_uploaded': 1,
              'local_path': null,
              'type': CnestFileTypeWire.fromFilename(f.name).index,
              ...derived,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      } else {
        final update = <String, Object?>{};
        derived.forEach((col, value) {
          if (row[col] != value) update[col] = value;
        });
        // Backfill accurate plaintext size / content hash from the create op
        // for rows first seeded by reconcile from the blob listing (which
        // only knows the ENCRYPTED size and no hash).
        final create = _createOp(allOps, id);
        if (create?.size != null && row['size_bytes'] != create!.size) {
          update['size_bytes'] = create.size;
        }
        if (create?.hash != null && row['content_hash'] == null) {
          update['content_hash'] = create!.hash;
        }
        // Converge created_at to the canonical, device-identical sort key
        // (capture time, else the create op's HLC wall). This is how the
        // ORIGIN's own row — inserted by addFile with a local wall clock —
        // adopts the SAME value every peer derives, so the gallery order is
        // identical on S and V. Left untouched for rows with no create op
        // (legacy / reconcile-only) so their cloud created-time survives.
        final canonicalWall = create?.captured ?? _createWall(opRows, id);
        if (canonicalWall != null && row['created_at'] != canonicalWall) {
          update['created_at'] = canonicalWall;
        }
        if (update.isNotEmpty) {
          batch.update('files', update, where: 'id = ?', whereArgs: [id]);
        }
      }
    }

    // ---- Folders: a FULLY derived table --------------------------------
    // Every folder row is a pure function of the log (no blobs, no
    // reconcile, no op-less legacy rows): upsert everything replay knows —
    // deleted folders keep their rows for the Recycle Bin — and drop rows
    // replay doesn't (purgeFolder is terminal). Same one-derived-map
    // discipline as files.
    final folderRows = await db.query('folders',
        where: 'account_id = ?', whereArgs: [accountId]);
    final existingFolders = {
      for (final r in folderRows) r['id'] as String: r
    };
    // Effective hidden = own flag OR any ancestor's, walked over the SAME
    // normalized parent chain the rows store (deleted folders keep the raw
    // pointer, live folders resolve live-or-root) — a pure function of
    // replay state, so it converges like every other derived column.
    final effHidden = <String, bool>{};
    bool isEffHidden(String startId) {
      final memo = effHidden[startId];
      if (memo != null) return memo;
      var result = false;
      String? cursor = startId;
      final seen = <String>{};
      while (cursor != null && seen.add(cursor)) {
        final f = state.folders[cursor];
        if (f == null) break;
        if (f.hidden) {
          result = true;
          break;
        }
        cursor = f.deleted ? f.parentId : liveOrRoot(f.parentId);
      }
      effHidden[startId] = result;
      return result;
    }

    for (final e in state.folders.entries) {
      final id = e.key;
      final f = e.value;
      final derived = <String, Object?>{
        'name': f.name,
        'parent_id': f.deleted ? f.parentId : liveOrRoot(f.parentId),
        'is_deleted': f.deleted ? 1 : 0,
        'deleted_at': f.deleted ? f.tombstoneWall : null,
        'deleted_by_folder_id': f.deletedByFolderId,
        // Device-identical folder ordering: the createFolder op's HLC wall.
        'created_at': _folderCreateWall(opRows, id),
        // Pure function of the (synced) id — converges by construction.
        'is_system': SystemFolders.isSystemId(id) ? 1 : 0,
        'is_hidden': f.hidden ? 1 : 0,
        'hidden_effective': isEffHidden(id) ? 1 : 0,
      };
      final row = existingFolders[id];
      if (row == null) {
        batch.insert(
            'folders',
            {'id': id, 'account_id': accountId, ...derived},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      } else {
        final update = <String, Object?>{};
        derived.forEach((col, value) {
          if (row[col] != value) update[col] = value;
        });
        if (update.isNotEmpty) {
          batch.update('folders', update, where: 'id = ?', whereArgs: [id]);
        }
      }
    }
    for (final id in existingFolders.keys) {
      if (!state.folders.containsKey(id)) {
        batch.delete('folders', where: 'id = ?', whereArgs: [id]);
      }
    }

    // ---- Albums: fully derived, SCOPED to this account's synced rows ---
    // The materializer owns exactly `is_smart = 0 AND account_id = <this>`.
    // Smart albums/playlists (is_smart = 1, account_id NULL) and other
    // accounts' rows are structurally out of reach — the scoped DELETEs
    // are the guard a shared table needs. deleteAlbum is terminal, so a
    // deleted album simply isn't in replay state and its row (and
    // memberships) drop everywhere.
    final albumRows = await db.query('albums',
        where: 'is_smart = 0 AND account_id = ?', whereArgs: [accountId]);
    final existingAlbums = {for (final r in albumRows) r['id'] as String: r};
    for (final e in state.albums.entries) {
      final id = e.key;
      final a = e.value;
      final createWall = _albumCreateWall(opRows, id);
      final derived = <String, Object?>{
        'name': a.name,
        'cover_file_id': a.coverFileId,
        'kind': a.isAudio ? 'audio' : 'photo',
        'is_smart': 0,
        'smart_query': null,
        'created_at': createWall,
        'updated_at': createWall,
      };
      final row = existingAlbums[id];
      if (row == null) {
        batch.insert('albums', {'id': id, 'account_id': accountId, ...derived},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      } else {
        final update = <String, Object?>{};
        derived.forEach((col, value) {
          if (row[col] != value) update[col] = value;
        });
        if (update.isNotEmpty) {
          batch.update('albums', update, where: 'id = ?', whereArgs: [id]);
        }
      }
    }
    for (final id in existingAlbums.keys) {
      if (!state.albums.containsKey(id)) {
        batch.delete('albums', where: 'id = ?', whereArgs: [id]);
        batch.delete('album_files', where: 'album_id = ?', whereArgs: [id]);
      }
    }
    // Membership rows: delete-and-rewrite per synced album (pair counts are
    // small; correctness over cleverness). added_at = the winning add's
    // HLC wall, so in-album order is device-identical.
    for (final e in state.albums.entries) {
      batch.delete('album_files', where: 'album_id = ?', whereArgs: [e.key]);
      final members = state.albumMemberships[e.key] ?? const <String, int>{};
      for (final m in members.entries) {
        // Only pairs whose file replay knows: album_files.file_id carries a
        // real FK, and a pair referencing a file with no createFile op
        // anywhere (dishonest history) must not fail the whole batch.
        if (!state.files.containsKey(m.key)) continue;
        batch.insert(
            'album_files',
            {'album_id': e.key, 'file_id': m.key, 'added_at': m.value},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }

    await batch.commit(noResult: true);
    DatabaseService().notifyFilesChanged();
  }

  /// Detects edit-vs-delete conflicts to surface to the user: a file this
  /// device has a pending edit on (rename / move / favorite / restore) that
  /// a DIFFERENT device deleted or purged. Delete wins (the file is in the
  /// Recycle Bin, or gone if purged); this lets the UI say so plainly. Read
  /// after a sync; returns at most a handful of the most relevant.
  Future<List<SyncConflict>> detectConflicts() async {
    final db = await _db();
    final thisDevice = await _deviceId();
    final allOps =
        (await db.query('sync_ops', where: 'account_id = ?', whereArgs: [
      accountId
    ]))
            .map(_rowToOp)
            .toList();
    final state = replayOps(allOps);
    final purged = <String>{
      for (final op in allOps)
        if (op.kind == SyncOpKind.purgeFile) op.targetId,
    };

    // Items this device has a pending edit on.
    const editKinds = {
      'renameFile',
      'moveFile',
      'setFavorite',
      'setFileHidden',
      'restoreFile'
    };
    const folderEditKinds = {'renameFolder', 'moveFolder', 'setFolderHidden'};
    final pendingEdits = await db.query('sync_ops',
        where: 'account_id = ? AND pending = 1 AND device_id = ?',
        whereArgs: [accountId, thisDevice]);
    final myEditedIds = <String, String?>{
      for (final r in pendingEdits)
        if (editKinds.contains(r['kind'])) r['target_id'] as String: null,
    };
    final myEditedFolderIds = <String>{
      for (final r in pendingEdits)
        if (folderEditKinds.contains(r['kind'])) r['target_id'] as String,
    };
    if (myEditedIds.isEmpty && myEditedFolderIds.isEmpty) return const [];

    // Who deleted/purged each — only a FOREIGN deletion is a conflict.
    String? foreignDeleter(String id, Set<SyncOpKind> deleteKinds) {
      String? who;
      Hlc? best;
      for (final op in allOps) {
        if (op.targetId != id) continue;
        if (!deleteKinds.contains(op.kind)) continue;
        if (best == null || op.hlc > best) {
          best = op.hlc;
          who = op.deviceId;
        }
      }
      return (who != null && who != thisDevice) ? who : null;
    }

    final out = <SyncConflict>[];
    for (final id in myEditedIds.keys) {
      final isGone = purged.contains(id);
      final f = state.files[id];
      final isDeleted = isGone || (f?.deleted ?? false);
      if (!isDeleted) continue;
      final deleter =
          foreignDeleter(id, {SyncOpKind.deleteFile, SyncOpKind.purgeFile});
      if (deleter == null) continue;
      out.add(SyncConflict(
        fileId: id,
        fileName: f?.name ?? id,
        deleterDeviceId: deleter,
        purged: isGone,
      ));
    }
    // Folder analog: my pending rename/move on a folder a FOREIGN device
    // deleted (in the bin) or purged (absent from replay's folders map).
    for (final id in myEditedFolderIds) {
      final folder = state.folders[id];
      final isGone = folder == null;
      final isDeleted = isGone || folder.deleted;
      if (!isDeleted) continue;
      final deleter = foreignDeleter(
          id, {SyncOpKind.deleteFolder, SyncOpKind.purgeFolder});
      if (deleter == null) continue;
      out.add(SyncConflict(
        fileId: id,
        fileName: folder?.name ?? id,
        deleterDeviceId: deleter,
        purged: isGone,
        isFolder: true,
      ));
    }
    return out;
  }

  /// This device's moveFolder ops that the cycle rule skipped — the user's
  /// move silently didn't happen and they should hear it once. The caller
  /// (SyncCoordinator) dedups against an already-notified set; this method
  /// just reports the current deterministic truth.
  Future<List<UndoneFolderMove>> detectUndoneFolderMoves() async {
    final db = await _db();
    final thisDevice = await _deviceId();
    final allOps = (await db.query('sync_ops',
            where: 'account_id = ?', whereArgs: [accountId]))
        .map(_rowToOp)
        .toList();
    final state = replayOps(allOps);
    if (state.skippedFolderMoves.isEmpty) return const [];

    final byKey = {for (final op in allOps) op.opKey: op};
    final out = <UndoneFolderMove>[];
    for (final key in state.skippedFolderMoves) {
      final op = byKey[key];
      if (op == null || op.deviceId != thisDevice) continue;
      // Best-effort attribution: the latest FOREIGN move touching my
      // folder or my intended destination is the one that made mine a
      // cycle.
      String? winner;
      Hlc? best;
      for (final other in allOps) {
        if (other.kind != SyncOpKind.moveFolder) continue;
        if (other.deviceId == thisDevice) continue;
        if (other.targetId != op.targetId &&
            other.targetId != op.folderId) {
          continue;
        }
        if (best == null || other.hlc > best) {
          best = other.hlc;
          winner = other.deviceId;
        }
      }
      out.add(UndoneFolderMove(
        opKey: key,
        folderName: state.folders[op.targetId]?.name ?? op.targetId,
        otherDeviceId: winner,
      ));
    }
    return out;
  }

  /// Full resync for a device returning from beyond the compaction horizon
  /// (completed in 2e once snapshots exist). The critical property is
  /// already enforced HERE: surviving local rows are NOT re-recorded as
  /// ops — the merged log is adopted as truth, and rows the log doesn't
  /// know remain local-only for Vault Health to surface.
  Future<void> fullResync() async {
    final db = await _db();
    await db.delete('sync_seen_segments',
        where: 'account_id = ?', whereArgs: [accountId]);
    await db.delete('sync_ops',
        where: 'account_id = ? AND pending = 0', whereArgs: [accountId]);
    await pullAndMerge();
  }

  // ---------------------------------------------------------------------
  // Row <-> op plumbing
  // ---------------------------------------------------------------------

  Map<String, Object?> _opToRow(SyncOp op, {required bool pending}) => {
        'op_key': op.opKey,
        'account_id': accountId,
        'device_id': op.deviceId,
        'seq': op.seq,
        'hlc_wall': op.hlc.wallMs,
        'hlc_counter': op.hlc.counter,
        // kindName, not kind.name: an unknown op keeps its ORIGINAL kind
        // string so it round-trips verbatim through rows and snapshots.
        'kind': op.kindName,
        'target_id': op.targetId,
        'name': op.name,
        'folder_id': op.folderId,
        'favorite': op.favorite == null ? null : (op.favorite! ? 1 : 0),
        'content_hash': op.hash,
        'size_bytes': op.size,
        'captured_at': op.captured,
        'pending': pending ? 1 : 0,
      };

  SyncOp _rowToOp(Map<String, Object?> row) => SyncOp.fromRow(row);

  /// The createFile op for a file id (carries name/hash/size/captured), or null.
  SyncOp? _createOp(List<SyncOp> ops, String id) {
    for (final op in ops) {
      if (op.kind == SyncOpKind.createFile && op.targetId == id) return op;
    }
    return null;
  }

  int? _createWall(List<Map<String, Object?>> opRows, String id) {
    for (final r in opRows) {
      if (r['target_id'] == id && r['kind'] == SyncOpKind.createFile.name) {
        return r['hlc_wall'] as int;
      }
    }
    return null;
  }

  int? _folderCreateWall(List<Map<String, Object?>> opRows, String id) {
    for (final r in opRows) {
      if (r['target_id'] == id &&
          r['kind'] == SyncOpKind.createFolder.name) {
        return r['hlc_wall'] as int;
      }
    }
    return null;
  }

  int? _albumCreateWall(List<Map<String, Object?>> opRows, String id) {
    for (final r in opRows) {
      if (r['target_id'] == id && r['kind'] == SyncOpKind.createAlbum.name) {
        return r['hlc_wall'] as int;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Per-account engine state
  // ---------------------------------------------------------------------

  Future<
      ({
        int hlcWall,
        int hlcCounter,
        int nextSeq,
        int nextSegment,
        int lastPullWall
      })> _loadState(DatabaseExecutor db) async {
    final rows = await db.query('sync_state',
        where: 'account_id = ?', whereArgs: [accountId], limit: 1);
    if (rows.isEmpty) {
      return (
        hlcWall: 0,
        hlcCounter: 0,
        nextSeq: 0,
        nextSegment: 0,
        lastPullWall: 0
      );
    }
    final r = rows.first;
    return (
      hlcWall: r['hlc_wall'] as int,
      hlcCounter: r['hlc_counter'] as int,
      nextSeq: r['next_seq'] as int,
      nextSegment: r['next_segment'] as int,
      lastPullWall: (r['last_pull_wall'] as int?) ?? 0,
    );
  }

  Future<void> _saveState(
    DatabaseExecutor db, {
    required int hlcWall,
    required int hlcCounter,
    required int nextSeq,
    required int nextSegment,
    required int lastPullWall,
  }) async {
    await db.insert(
        'sync_state',
        {
          'account_id': accountId,
          'hlc_wall': hlcWall,
          'hlc_counter': hlcCounter,
          'next_seq': nextSeq,
          'next_segment': nextSegment,
          'last_pull_wall': lastPullWall,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
