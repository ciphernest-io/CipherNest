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
import 'package:sqflite/sqflite.dart';

import '../../src/models/file_model.dart';
import '../database_service.dart';
import '../device_identity_service.dart';
import 'hlc.dart';
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

  const LocalSyncAction({
    required this.kind,
    required this.targetId,
    this.name,
    this.folderId,
    this.favorite,
  });
}

class SyncEngine {
  final SyncTransport transport;
  final String accountId;
  final Future<Database> Function() _db;
  final Future<String> Function() _deviceId;

  /// Milliseconds a tombstone stays materialized for devices that never had
  /// the row — matches the Recycle Bin TTL, so ancient ghosts don't appear
  /// in a fresh device's bin.
  static const int ghostTombstoneTtlMs = 30 * 24 * 60 * 60 * 1000;

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
      );
      await txn.insert('sync_ops', _opToRow(op, pending: true),
          conflictAlgorithm: ConflictAlgorithm.ignore);
      await _saveState(
        txn,
        hlcWall: hlc.wallMs,
        hlcCounter: hlc.counter,
        nextSeq: state.nextSeq + 1,
        nextSegment: state.nextSegment,
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
            nextSegment: s.nextSegment + 1);
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
      if (SegmentCodec.parseName(name) == null) continue; // snapshots: 2e
      final bytes = await transport.downloadObject(obj['id'] as String);
      final ops = await SegmentCodec.tryOpen(bytes);
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
            nextSegment: s.nextSegment);
      });
      merged += ops.length;
    }

    if (merged > 0 || unreadable > 0) {
      await applyMergedState();
    }
    return unreadable;
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
    final opRows = await db.query('sync_ops',
        where: 'account_id = ?', whereArgs: [accountId]);
    if (opRows.isEmpty) return;
    final state = replayOps(opRows.map(_rowToOp));

    final fileRows = await db.query('files',
        columns: ['id', 'filename', 'is_favorite', 'is_deleted'],
        where: 'account_id = ?',
        whereArgs: [accountId]);
    final existing = {for (final r in fileRows) r['id'] as String: r};

    final batch = db.batch();
    final nowMs = _wallClock();
    for (final e in state.files.entries) {
      final id = e.key;
      final f = e.value;
      final row = existing[id];
      if (row == null) {
        if (f.deleted) {
          // Ghost rule: a tombstone for a file this device never had only
          // materializes while it would still be visible in the bin.
          final tombstoneAge = nowMs - _tombstoneWall(opRows, id);
          if (tombstoneAge > ghostTombstoneTtlMs) continue;
        }
        batch.insert(
            'files',
            {
              'id': id,
              'cloud_id': null, // reconcile joins the blob by stem later
              'account_id': accountId,
              'filename': f.name,
              'size_bytes': 0,
              'created_at': _createWall(opRows, id) ?? nowMs,
              'is_uploaded': 1,
              'local_path': null,
              'is_favorite': f.favorite ? 1 : 0,
              'is_deleted': f.deleted ? 1 : 0,
              'deleted_at': f.deleted ? _tombstoneWall(opRows, id) : null,
              'type': CnestFileTypeWire.fromFilename(f.name).index,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      } else {
        final update = <String, Object?>{};
        if (row['filename'] != f.name) update['filename'] = f.name;
        if ((row['is_favorite'] == 1) != f.favorite) {
          update['is_favorite'] = f.favorite ? 1 : 0;
        }
        if ((row['is_deleted'] == 1) != f.deleted) {
          update['is_deleted'] = f.deleted ? 1 : 0;
          update['deleted_at'] =
              f.deleted ? _tombstoneWall(opRows, id) : null;
        }
        if (update.isNotEmpty) {
          batch.update('files', update, where: 'id = ?', whereArgs: [id]);
        }
      }
    }
    await batch.commit(noResult: true);
    DatabaseService().notifyFilesChanged();
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
        'kind': op.kind.name,
        'target_id': op.targetId,
        'name': op.name,
        'folder_id': op.folderId,
        'favorite': op.favorite == null ? null : (op.favorite! ? 1 : 0),
        'pending': pending ? 1 : 0,
      };

  SyncOp _rowToOp(Map<String, Object?> row) => SyncOp(
        kind: SyncOpKind.values.firstWhere((k) => k.name == row['kind']),
        deviceId: row['device_id'] as String,
        seq: row['seq'] as int,
        hlc: Hlc(row['hlc_wall'] as int, row['hlc_counter'] as int),
        targetId: row['target_id'] as String,
        name: row['name'] as String?,
        folderId: row['folder_id'] as String?,
        favorite:
            row['favorite'] == null ? null : (row['favorite'] as int) == 1,
      );

  int _tombstoneWall(List<Map<String, Object?>> opRows, String id) {
    var wall = 0;
    for (final r in opRows) {
      if (r['target_id'] == id && r['kind'] == SyncOpKind.deleteFile.name) {
        final w = r['hlc_wall'] as int;
        if (w > wall) wall = w;
      }
    }
    return wall;
  }

  int? _createWall(List<Map<String, Object?>> opRows, String id) {
    for (final r in opRows) {
      if (r['target_id'] == id && r['kind'] == SyncOpKind.createFile.name) {
        return r['hlc_wall'] as int;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Per-account engine state
  // ---------------------------------------------------------------------

  Future<({int hlcWall, int hlcCounter, int nextSeq, int nextSegment})>
      _loadState(DatabaseExecutor db) async {
    final rows = await db.query('sync_state',
        where: 'account_id = ?', whereArgs: [accountId], limit: 1);
    if (rows.isEmpty) {
      return (hlcWall: 0, hlcCounter: 0, nextSeq: 0, nextSegment: 0);
    }
    final r = rows.first;
    return (
      hlcWall: r['hlc_wall'] as int,
      hlcCounter: r['hlc_counter'] as int,
      nextSeq: r['next_seq'] as int,
      nextSegment: r['next_segment'] as int,
    );
  }

  Future<void> _saveState(
    DatabaseExecutor db, {
    required int hlcWall,
    required int hlcCounter,
    required int nextSeq,
    required int nextSegment,
  }) async {
    await db.insert(
        'sync_state',
        {
          'account_id': accountId,
          'hlc_wall': hlcWall,
          'hlc_counter': hlcCounter,
          'next_seq': nextSeq,
          'next_segment': nextSegment,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
