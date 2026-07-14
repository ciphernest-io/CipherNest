/// Adapter: the REAL op-log core (lib/services/sync/) driven by the sim
/// harness. From Stage 2b onward, every harness run judges production code.
///
/// What is real here: HLC, op vocabulary, total order, deterministic replay
/// (all imported from lib/). What is simulated: storage (plain segment
/// objects in SimCloud — the HPKE sealing added in 2c is orthogonal to
/// ordering/convergence and has its own tests) and the local pending queue
/// (SQLite-backed in 2d).
library;

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
    final segments = cloud.list(deviceId, prefix: segmentPrefix);
    for (final seg in segments) {
      if (_seenSegments.contains(seg.name)) continue;
      final payload = cloud.get(deviceId, seg.name);
      final ops = payload == null ? null : await decodeSegment(payload);
      if (ops != null) {
        for (final op in ops) {
          _log.putIfAbsent(op.opKey, () => op);
          _lastHlc = Hlc.receive(_lastHlc, op.hlc, clock());
        }
        // Only a successfully decoded segment counts as seen — an
        // unreadable one must be retried/surfaced, never absorbed.
        _seenSegments.add(seg.name);
      }
    }
  }

  @override
  Future<void> maybeCompact(SimCloud cloud) async {
    // Stage 2e. Until then the log only grows — invariant-safe by default.
  }

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
