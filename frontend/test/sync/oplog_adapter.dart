/// Adapter: the REAL op-log core (lib/services/sync/) driven by the sim
/// harness. From Stage 2b onward, every harness run judges production code.
///
/// What is real here: HLC, op vocabulary, total order, deterministic replay
/// (all imported from lib/). What is simulated: storage (plain segment
/// objects in SimCloud — the HPKE sealing added in 2c is orthogonal to
/// ordering/convergence and has its own tests) and the local pending queue
/// (SQLite-backed in 2d).
library;

import 'package:ciphernest/services/sync/compaction.dart';
import 'package:ciphernest/services/sync/hlc.dart';
import 'package:ciphernest/services/sync/op_replay.dart';
import 'package:ciphernest/services/sync/sync_op.dart';

import 'sim_cloud.dart';
import 'sim_engine.dart';
import 'sim_model.dart';

/// Maps a sim user action onto the production op vocabulary.
SyncOp opFromAction(
  LocalAction a, {
  required String deviceId,
  required int seq,
  required Hlc hlc,
}) {
  final kind = switch (a.kind) {
    ActionKind.createFile => SyncOpKind.createFile,
    ActionKind.deleteFile => SyncOpKind.deleteFile,
    ActionKind.restoreFile => SyncOpKind.restoreFile,
    ActionKind.purgeFile => SyncOpKind.purgeFile,
    ActionKind.renameFile => SyncOpKind.renameFile,
    ActionKind.moveFile => SyncOpKind.moveFile,
    ActionKind.setFavorite => SyncOpKind.setFavorite,
    ActionKind.createFolder => SyncOpKind.createFolder,
    ActionKind.deleteFolder => SyncOpKind.deleteFolder,
  };
  return SyncOp(
    kind: kind,
    deviceId: deviceId,
    seq: seq,
    hlc: hlc,
    targetId: a.targetId,
    name: a.name,
    folderId: a.folderId,
    favorite: a.favorite,
  );
}

class OpLogSimEngine implements SimSyncEngine {
  static const String segmentPrefix = 'oplog/ops_';
  static const String snapshotPrefix = 'oplog/state_';

  @override
  final String deviceId;
  @override
  final SimTime Function() clock;

  /// All ops this device knows, keyed by idempotency key. In production
  /// this is the local segment cache; SQLite is a VIEW over it (2d).
  final Map<String, SyncOp> _log = {};

  /// Local ops not yet durably uploaded. Survives crashes (SQLite-backed
  /// in production); dies only with a reinstall — which the harness models
  /// by constructing a fresh engine.
  final List<SyncOp> _pending = [];

  /// The batch currently being written to the cloud, with its fixed
  /// segment name. Kept until the segment is confirmed present so a crash
  /// between `put` and local bookkeeping re-checks instead of re-appending
  /// under a new name (which would duplicate ops — harmless, but sloppy —
  /// or, under the append-only rule, throw).
  List<SyncOp> _inFlight = [];
  int _segSeq = 0;

  final Set<String> _seenSegments = {};

  Hlc _lastHlc = Hlc.zero;
  int _nextSeq = 0;
  bool _locked = false;

  OpLogSimEngine(this.deviceId, this.clock);

  @override
  set locked(bool value) => _locked = value;

  @override
  void applyLocal(LocalAction action) {
    _lastHlc = Hlc.send(_lastHlc, clock());
    final op = opFromAction(
      action,
      deviceId: deviceId,
      seq: _nextSeq++,
      hlc: _lastHlc,
    );
    _log[op.opKey] = op;
    _pending.add(op);
  }

  String get _currentSegmentName => '$segmentPrefix${deviceId}_$_segSeq';

  /// Payload codec hooks — the plain adapter stores op lists directly; the
  /// sealed adapter (Stage 2c) overrides with the REAL HPKE segment codec.
  Future<Object> encodeSegment(List<SyncOp> ops) async =>
      List<SyncOp>.unmodifiable(ops);

  Future<List<SyncOp>?> decodeSegment(Object payload) async =>
      payload is List ? payload.whereType<SyncOp>().toList() : null;

  @override
  Future<void> syncCycle(SimCloud cloud) async {
    // ---- PUSH (works while locked: appending needs no decrypt) ----------
    // Crash-safety: the segment name is fixed BEFORE the put; on retry we
    // first check whether the put already landed. Every prefix of this
    // sequence leaves either "segment absent, batch still local" or
    // "segment present, batch clearable" — nothing in between.
    while (_inFlight.isNotEmpty || _pending.isNotEmpty) {
      if (_inFlight.isEmpty) {
        _inFlight = List.of(_pending);
        _pending.clear();
      }
      final name = _currentSegmentName;
      // Seal BEFORE the existence check: with a crash budget the put must
      // be the very next cloud call after the check, or the window between
      // them stops being the one we think we are testing.
      final sealed = await encodeSegment(_inFlight);
      final existing = cloud.get(deviceId, name);
      if (existing == null) {
        cloud.put(deviceId, name, sealed);
      }
      _seenSegments.add(name);
      _segSeq++;
      _inFlight = [];
    }

    // ---- PULL + MERGE (requires decrypt capability -> not while locked) -
    if (_locked) return;
    // Snapshots first, then segments — either provides ops; merging both is
    // idempotent (dedupe by op key).
    for (final prefix in [snapshotPrefix, segmentPrefix]) {
      final objects = cloud.list(deviceId, prefix: prefix);
      for (final obj in objects) {
        if (_seenSegments.contains(obj.name)) continue;
        final payload = cloud.get(deviceId, obj.name);
        final ops = payload == null ? null : await decodeSegment(payload);
        if (ops != null) {
          for (final op in ops) {
            _log.putIfAbsent(op.opKey, () => op);
            _lastHlc = Hlc.receive(_lastHlc, op.hlc, clock());
          }
          _seenSegments.add(obj.name);
        }
      }
    }
  }

  int _snapSeq = 0;

  @override
  Future<void> maybeCompact(SimCloud cloud) async {
    if (_locked) return;
    // Fold objects older than the fold floor (by PROVIDER upload time).
    final foldable = <CloudObject>[];
    for (final prefix in [snapshotPrefix, segmentPrefix]) {
      for (final obj in cloud.list(deviceId, prefix: prefix)) {
        if (cloud.now - obj.uploadedAt >= Compaction.foldableAgeMs) {
          foldable.add(obj);
        }
      }
    }
    if (foldable.length < Compaction.minFoldable) return;

    // Open all; any unreadable aborts (never delete what we can't read).
    final foldedNames = <String>[];
    final byKey = <String, SyncOp>{};
    for (final obj in foldable) {
      final ops = await decodeSegment(cloud.get(deviceId, obj.name)!);
      if (ops == null) return;
      foldedNames.add(obj.name);
      for (final op in ops) {
        byKey.putIfAbsent(op.opKey, () => op);
      }
    }

    final snapOps = Compaction.snapshotOps(byKey.values.toList());
    final snapName = '$snapshotPrefix${deviceId}_$_snapSeq';
    _snapSeq++;

    final sealed = await encodeSnapshot(snapOps);
    if (cloud.get(deviceId, snapName) == null) {
      cloud.put(deviceId, snapName, sealed);
    }
    // Read-back verify before deleting anything.
    final verify =
        await decodeSegment(cloud.get(deviceId, snapName)!);
    if (verify == null || verify.length != snapOps.length) return;

    for (final name in foldedNames) {
      cloud.delete(deviceId, name);
    }
    _seenSegments.add(snapName);
    // CRITICAL: merge the folded ops into our OWN log. Compaction reads
    // segments from the cloud that this device may NOT have merged yet;
    // without this, folding + deleting them + marking the snapshot seen
    // would lose those ops from this device's view forever (harness seed 9).
    // No GC: folding is verbatim, so replay(snapshot) == replay(segments).
    for (final op in snapOps) {
      _log.putIfAbsent(op.opKey, () => op);
    }
  }

  /// Debug hook only.
  List<SyncOp> get logForSpy => _log.values.toList();

  /// Snapshot payload codec — plain adapter stores op lists; sealed adapter
  /// overrides with the real snapshot codec.
  Future<Object> encodeSnapshot(List<SyncOp> ops) async =>
      List<SyncOp>.unmodifiable(ops);

  @override
  MaterializedState materialize() {
    final state = replayOps(_log.values);
    final live = <String, FileMeta>{};
    final binned = <String, FileMeta>{};
    for (final e in state.files.entries) {
      final meta = FileMeta(
        name: e.value.name,
        folderId: e.value.folderId,
        favorite: e.value.favorite,
      );
      (e.value.deleted ? binned : live)[e.key] = meta;
    }
    final folders = <String, FolderMeta>{
      for (final e in state.folders.entries)
        if (!e.value.deleted)
          e.key: FolderMeta(name: e.value.name, parentId: e.value.parentId),
    };
    return MaterializedState(live: live, binned: binned, folders: folders);
  }
}
