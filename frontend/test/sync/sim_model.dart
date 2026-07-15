/// Shared value types for the multi-device sync property harness.
///
/// Everything here is SIMULATION vocabulary — the harness's model of user
/// actions and device state. The production op-log (built after this
/// harness, per the approved plan) is judged by adapting it to
/// [SimSyncEngine] in sim_engine.dart; these types never leak into lib/.
library;

import 'package:flutter_test/flutter_test.dart';

/// Milliseconds since sim epoch. The harness owns global time; devices see
/// it only through their skewed clocks.
typedef SimTime = int;

const int msPerDay = 24 * 60 * 60 * 1000;

// ---------------------------------------------------------------------------
// User actions (what a human does on one device)
// ---------------------------------------------------------------------------

enum ActionKind {
  createFile,
  deleteFile,
  restoreFile, // un-delete from the Recycle Bin
  purgeFile, // permanent deletion (30-day bin sweep) — terminal
  renameFile,
  moveFile,
  setFavorite,
  createFolder,
  deleteFolder,
}

class LocalAction {
  final ActionKind kind;
  final int deviceIndex;

  /// Global sim time at which the action happened (the device records it
  /// with its own skewed clock — the harness keeps the truth).
  final SimTime at;

  /// File or folder id the action targets (uuid-like string).
  final String targetId;

  /// New name for create/rename; folder name for createFolder.
  final String? name;

  /// Destination folder id for move/create (null = root).
  final String? folderId;

  final bool? favorite;

  const LocalAction({
    required this.kind,
    required this.deviceIndex,
    required this.at,
    required this.targetId,
    this.name,
    this.folderId,
    this.favorite,
  });

  @override
  String toString() =>
      'LocalAction(${kind.name} dev=$deviceIndex t=$at id=$targetId'
      '${name != null ? ' name=$name' : ''}'
      '${folderId != null ? ' folder=$folderId' : ''}'
      '${favorite != null ? ' fav=$favorite' : ''})';
}

// ---------------------------------------------------------------------------
// Materialized state (what a device would show its user)
// ---------------------------------------------------------------------------

class FileMeta {
  final String name;
  final String? folderId;
  final bool favorite;

  const FileMeta({
    required this.name,
    required this.folderId,
    required this.favorite,
  });

  @override
  bool operator ==(Object other) =>
      other is FileMeta &&
      other.name == name &&
      other.folderId == folderId &&
      other.favorite == favorite;

  @override
  int get hashCode => Object.hash(name, folderId, favorite);

  @override
  String toString() => 'FileMeta($name, folder=$folderId, fav=$favorite)';
}

class FolderMeta {
  final String name;
  final String? parentId;

  const FolderMeta({required this.name, required this.parentId});

  @override
  bool operator ==(Object other) =>
      other is FolderMeta && other.name == name && other.parentId == parentId;

  @override
  int get hashCode => Object.hash(name, parentId);

  @override
  String toString() => 'FolderMeta($name, parent=$parentId)';
}

/// A device's user-visible state after materialization.
///
/// `live` and `binned` are disjoint. A file in neither is ABSENT — and an
/// absent file that was ever durably created is the "vanished" condition
/// invariant 3 exists to kill.
class MaterializedState {
  final Map<String, FileMeta> live;
  final Map<String, FileMeta> binned;
  final Map<String, FolderMeta> folders;

  const MaterializedState({
    required this.live,
    required this.binned,
    required this.folders,
  });

  static const empty =
      MaterializedState(live: {}, binned: {}, folders: {});

  @override
  bool operator ==(Object other) =>
      other is MaterializedState &&
      _mapEq(other.live, live) &&
      _mapEq(other.binned, binned) &&
      _mapEq(other.folders, folders);

  @override
  int get hashCode =>
      Object.hash(live.length, binned.length, folders.length);

  static bool _mapEq<V>(Map<String, V> a, Map<String, V> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  /// Human-readable diff for failure messages.
  String diff(MaterializedState other) {
    final out = StringBuffer();
    void section<V>(String label, Map<String, V> a, Map<String, V> b) {
      for (final k in {...a.keys, ...b.keys}) {
        if (a[k] != b[k]) out.writeln('  $label[$k]: ${a[k]} vs ${b[k]}');
      }
    }

    section('live', live, other.live);
    section('binned', binned, other.binned);
    section('folders', folders, other.folders);
    return out.isEmpty ? '  (states identical)' : out.toString();
  }
}

// ---------------------------------------------------------------------------
// Failure reporting
// ---------------------------------------------------------------------------

class InvariantViolation {
  final int invariant; // 1 = convergence, 2 = resurrection, 3 = vanish
  final String detail;
  const InvariantViolation(this.invariant, this.detail);

  @override
  String toString() => 'INVARIANT $invariant VIOLATED: $detail';
}

/// Fails the test with the seed front and center so any run reproduces.
Never failWithSeed(int seed, List<InvariantViolation> violations) {
  fail('Sync invariants violated (reproduce with seed=$seed):\n'
      '${violations.map((v) => '  $v').join('\n')}');
}
