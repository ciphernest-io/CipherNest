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
  moveFolder, // reparent; cycle-forming moves are skipped deterministically
  renameFolder,
  deleteFolder,
  restoreFolder, // un-delete folder + its own cascade as a unit (Model A)
  purgeFolder, // permanent deletion of the folder entity — terminal
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

  /// Cascade cause (Model A): the targeted root of the deleteFolder whose
  /// cascade binned this file; null = individually deleted, or live.
  /// Included in equality — devices must agree on WHY something is binned,
  /// or restoreFolder would diverge.
  final String? deletedByFolder;

  const FileMeta({
    required this.name,
    required this.folderId,
    required this.favorite,
    this.deletedByFolder,
  });

  @override
  bool operator ==(Object other) =>
      other is FileMeta &&
      other.name == name &&
      other.folderId == folderId &&
      other.favorite == favorite &&
      other.deletedByFolder == deletedByFolder;

  @override
  int get hashCode => Object.hash(name, folderId, favorite, deletedByFolder);

  @override
  String toString() => 'FileMeta($name, folder=$folderId, fav=$favorite'
      '${deletedByFolder != null ? ', by=$deletedByFolder' : ''})';
}

class FolderMeta {
  final String name;
  final String? parentId;

  /// Cascade cause, mirroring [FileMeta.deletedByFolder]: null on a folder
  /// the user deleted directly (the bin entry), the targeted root's id on
  /// cascade-deleted descendants.
  final String? deletedByFolder;

  const FolderMeta({
    required this.name,
    required this.parentId,
    this.deletedByFolder,
  });

  @override
  bool operator ==(Object other) =>
      other is FolderMeta &&
      other.name == name &&
      other.parentId == parentId &&
      other.deletedByFolder == deletedByFolder;

  @override
  int get hashCode => Object.hash(name, parentId, deletedByFolder);

  @override
  String toString() => 'FolderMeta($name, parent=$parentId'
      '${deletedByFolder != null ? ', by=$deletedByFolder' : ''})';
}

/// A device's user-visible state after materialization.
///
/// `live` and `binned` are disjoint (same for `folders`/`binnedFolders`).
/// A file in neither is ABSENT — and an absent file that was ever durably
/// created is the "vanished" condition invariant 3 exists to kill.
///
/// Normalization contract (invariant 4 enforces it): LIVE entries' folder
/// pointers are resolved — a live file's folderId / live folder's parentId
/// is either null or a key of [folders]. BINNED entries keep their RAW
/// pointers (possibly into [binnedFolders] or nowhere) — the bin needs the
/// original context, and a child must be able to rejoin a later-restored
/// parent.
class MaterializedState {
  final Map<String, FileMeta> live;
  final Map<String, FileMeta> binned;
  final Map<String, FolderMeta> folders;
  final Map<String, FolderMeta> binnedFolders;

  const MaterializedState({
    required this.live,
    required this.binned,
    required this.folders,
    required this.binnedFolders,
  });

  static const empty = MaterializedState(
      live: {}, binned: {}, folders: {}, binnedFolders: {});

  @override
  bool operator ==(Object other) =>
      other is MaterializedState &&
      _mapEq(other.live, live) &&
      _mapEq(other.binned, binned) &&
      _mapEq(other.folders, folders) &&
      _mapEq(other.binnedFolders, binnedFolders);

  @override
  int get hashCode => Object.hash(
      live.length, binned.length, folders.length, binnedFolders.length);

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
    section('binnedFolders', binnedFolders, other.binnedFolders);
    return out.isEmpty ? '  (states identical)' : out.toString();
  }
}

// ---------------------------------------------------------------------------
// Failure reporting
// ---------------------------------------------------------------------------

class InvariantViolation {
  // 1 = convergence, 2 = resurrection, 3 = vanish,
  // 4 = tree safety (acyclic, parents resolve, no orphaned live file)
  final int invariant;
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
