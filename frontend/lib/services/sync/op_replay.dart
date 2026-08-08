/// Deterministic replay: op set -> vault state. The heart of convergence.
///
/// Properties this module owes the three invariants:
///  * ORDER-INDEPENDENT INPUT: replay(ops) is a pure function of the SET of
///    ops — any arrival order, any duplication, same result. (Sort by the
///    global total order, dedupe by op key, fold.)
///  * DELETE WINS, SOFTLY: a tombstone permanently ends a file's live
///    lifecycle; later-ordering edits on it are ignored. The file stays in
///    the bin (never erased by replay) — recoverable, per the Recycle Bin
///    design.
///  * CREATES ARE UNIQUE: file ids are UUIDs minted once; a duplicate
///    create (same id) is dead on arrival (first in total order wins).
///  * TREE SAFETY: folder moves that would create a cycle at their point in
///    the fold are skipped (deterministically — same order everywhere, so
///    the same op is skipped everywhere). Files pointing into deleted or
///    unknown folders materialize at root — a MATERIALIZATION rule, applied
///    by every consumer of this state (the SQLite writer and the harness
///    adapters), never by mutating the fold state itself: the raw pointer
///    is what lets a child rejoin a later-restored parent.
///  * FOLDER DELETE IS RESTORABLE AS A UNIT (Model A): the cascade stamps
///    every binned item with the TARGETED folder's id
///    ([FileState.deletedByFolderId]); restoreFolder un-deletes the folder
///    plus exactly the cause-matching items. Individually-deleted items
///    (null cause) are never absorbed and never restored by the folder.
///  * TOMBSTONE WALLS ARE EXPLICIT: [FileState.tombstoneWall] records the
///    HLC wall of whichever op flipped deleted — deleteFile or a cascade —
///    so the materializer's deleted_at is never inferred (the deleted_at=0
///    instant-purge lesson).
///
/// Semantics deliberately mirror test/sync/state_machine.dart (the
/// sequential reference): with no concurrency, replay must equal the
/// reference exactly.
library;

import 'sync_op.dart';

class FileState {
  final String name;
  final String? folderId;
  final bool favorite;
  final bool deleted;

  /// Cascade cause: the TARGETED root of the deleteFolder whose cascade
  /// binned this file; null = deleted individually (or live). One user
  /// action = one bin entry, however deep the subtree — descendants carry
  /// the root's id, not their immediate parent's. Explicit state, never
  /// inferred from a missing timestamp (the deleted_at=0 lesson).
  final String? deletedByFolderId;

  /// HLC wall of whichever op flipped [deleted] to true — deleteFile OR a
  /// deleteFolder cascade. The materializer's deleted_at source; null while
  /// live.
  final int? tombstoneWall;

  const FileState({
    required this.name,
    required this.folderId,
    required this.favorite,
    required this.deleted,
    this.deletedByFolderId,
    this.tombstoneWall,
  });

  FileState copyWith({
    String? name,
    String? Function()? folderId,
    bool? favorite,
    bool? deleted,
    String? Function()? deletedByFolderId,
    int? Function()? tombstoneWall,
  }) =>
      FileState(
        name: name ?? this.name,
        folderId: folderId != null ? folderId() : this.folderId,
        favorite: favorite ?? this.favorite,
        deleted: deleted ?? this.deleted,
        deletedByFolderId: deletedByFolderId != null
            ? deletedByFolderId()
            : this.deletedByFolderId,
        tombstoneWall:
            tombstoneWall != null ? tombstoneWall() : this.tombstoneWall,
      );
}

class FolderState {
  final String name;
  final String? parentId;
  final bool deleted;

  /// Hidden from the specialized views (typed tabs, gallery, albums,
  /// stories, pickers). OWN flag only — subtree inheritance is computed at
  /// materialization (folders.hidden_effective). The Files browser and the
  /// Recycle Bin ignore it entirely.
  final bool hidden;

  /// Cascade cause, mirroring [FileState.deletedByFolderId]: null on the
  /// TARGETED folder (it is the bin entry), the targeted root's id on
  /// cascade-deleted descendants.
  final String? deletedByFolderId;

  /// HLC wall of the deleteFolder that binned this folder; null while live.
  final int? tombstoneWall;

  const FolderState({
    required this.name,
    required this.parentId,
    required this.deleted,
    this.hidden = false,
    this.deletedByFolderId,
    this.tombstoneWall,
  });

  FolderState copyWith({
    String? name,
    String? Function()? parentId,
    bool? deleted,
    bool? hidden,
    String? Function()? deletedByFolderId,
    int? Function()? tombstoneWall,
  }) =>
      FolderState(
        name: name ?? this.name,
        parentId: parentId != null ? parentId() : this.parentId,
        deleted: deleted ?? this.deleted,
        hidden: hidden ?? this.hidden,
        deletedByFolderId: deletedByFolderId != null
            ? deletedByFolderId()
            : this.deletedByFolderId,
        tombstoneWall:
            tombstoneWall != null ? tombstoneWall() : this.tombstoneWall,
      );
}

class VaultState {
  final Map<String, FileState> files;
  final Map<String, FolderState> folders;
  final Map<String, String> devices; // deviceId -> display name

  /// Op keys of moveFolder ops the Kleppmann cycle rule skipped — same set
  /// on every device (the skip is a function of the total order). The
  /// conflict-notice layer intersects this with the local device's own ops
  /// to tell the user their move was undone; replay itself never acts on it.
  final Set<String> skippedFolderMoves;

  const VaultState({
    required this.files,
    required this.folders,
    required this.devices,
    this.skippedFolderMoves = const {},
  });
}

/// Replays [ops] (any order, duplicates tolerated) into a [VaultState].
VaultState replayOps(Iterable<SyncOp> ops) {
  // 1. Dedupe by idempotency key. Duplicate keys carry identical content by
  //    construction (an op is written once and only copied thereafter).
  final byKey = <String, SyncOp>{};
  for (final op in ops) {
    byKey.putIfAbsent(op.opKey, () => op);
  }

  // 2. Global total order — identical on every device.
  final sorted = byKey.values.toList()..sort(SyncOp.compare);

  // 3. Fold.
  final files = <String, FileState>{};
  final folders = <String, FolderState>{};
  final devices = <String, String>{};
  // Permanently purged file ids. Purge is TERMINAL and order-independent:
  // once a file is purged (its blob physically deleted by the bin sweep) no
  // op — not even a later-ordering restore — can bring it back. Collected
  // across the whole fold, then applied at the end (end-of-fold so a
  // straggler create or a defensive pre-tombstone can't rebuild a row).
  final purged = <String>{};

  // Permanently purged FOLDER ids. Folders are purged INLINE (removed from
  // the map immediately) — unlike files there is no pre-tombstone or
  // straggler-create path that could rebuild one mid-fold, and inline
  // removal is what keeps replay equal to the sequential reference (a
  // later deleteFolder/moveFolder/moveFile targeting a purged folder must
  // see it already gone). The set only guards createFolder so a straggler
  // create with the same UUID stays dead — terminality, same as files.
  final purgedFolders = <String>{};

  // Cycle-skipped moveFolder op keys, reported via VaultState.
  final skippedFolderMoves = <String>{};

  String? liveFolderOrRoot(String? id) =>
      id != null && folders.containsKey(id) && !folders[id]!.deleted
          ? id
          : null;

  Set<String> liveSubtreeOf(String rootId) {
    final root = folders[rootId];
    if (root == null || root.deleted) return const {};
    final subtree = <String>{rootId};
    var grew = true;
    while (grew) {
      grew = false;
      for (final e in folders.entries) {
        if (e.value.deleted) continue;
        if (!subtree.contains(e.key) &&
            e.value.parentId != null &&
            subtree.contains(e.value.parentId)) {
          subtree.add(e.key);
          grew = true;
        }
      }
    }
    return subtree;
  }

  bool wouldCycle(String folderId, String? newParent) {
    var cursor = newParent;
    var hops = 0;
    while (cursor != null && hops++ < folders.length + 1) {
      if (cursor == folderId) return true;
      cursor = folders[cursor]?.parentId;
    }
    return false;
  }

  for (final op in sorted) {
    switch (op.kind) {
      case SyncOpKind.createFile:
        // First create in total order wins; the id is a UUID so a second
        // create is a protocol violation we neutralize rather than honor.
        if (files.containsKey(op.targetId)) break;
        files[op.targetId] = FileState(
          name: op.name ?? op.targetId,
          folderId: liveFolderOrRoot(op.folderId),
          favorite: false,
          deleted: false,
        );
      case SyncOpKind.deleteFile:
        final f = files[op.targetId];
        if (f == null) {
          // Defensive pre-tombstone: causally impossible for honest
          // histories (HLC orders a delete after the create its device
          // saw), but if it ever occurs the delete must still win.
          files[op.targetId] = FileState(
            name: op.targetId,
            folderId: null,
            favorite: false,
            deleted: true,
            tombstoneWall: op.hlc.wallMs,
          );
        } else if (!f.deleted) {
          files[op.targetId] = f.copyWith(
            deleted: true,
            tombstoneWall: () => op.hlc.wallMs,
          );
        } else {
          // Already binned (a concurrent cascade got there first): re-stamp
          // as an INDIVIDUAL bin entry. "I deleted this file myself" must
          // survive a restore of the folder whose cascade absorbed it —
          // delete wins over a concurrent restoreFolder (seed-178 lesson).
          // This also makes the pair commute: deleteFile+deleteFolder in
          // either order converge to (binned, cause null, deleteFile wall).
          files[op.targetId] = f.copyWith(
            deletedByFolderId: () => null,
            tombstoneWall: () => op.hlc.wallMs,
          );
        }
      case SyncOpKind.restoreFile:
        // Un-delete from the Recycle Bin. In the total order a restore the
        // user performed necessarily follows the delete they saw (HLC
        // causality), so folding it later is exactly right. A concurrent
        // delete elsewhere with a later HLC re-deletes — converged either
        // way, and the loser is always recoverable from the bin.
        final f = files[op.targetId];
        if (f != null && f.deleted) {
          files[op.targetId] = f.copyWith(
            deleted: false,
            deletedByFolderId: () => null,
            tombstoneWall: () => null,
          );
        }
      case SyncOpKind.purgeFile:
        purged.add(op.targetId);
      case SyncOpKind.renameFile:
        final f = files[op.targetId];
        if (f != null && !f.deleted && op.name != null) {
          files[op.targetId] = f.copyWith(name: op.name);
        }
      case SyncOpKind.moveFile:
        final f = files[op.targetId];
        if (f != null && !f.deleted) {
          files[op.targetId] =
              f.copyWith(folderId: () => liveFolderOrRoot(op.folderId));
        }
      case SyncOpKind.setFavorite:
        final f = files[op.targetId];
        if (f != null && !f.deleted && op.favorite != null) {
          files[op.targetId] = f.copyWith(favorite: op.favorite);
        }
      case SyncOpKind.createFolder:
        // Terminality guard: a straggler create for a purged folder id is
        // dead on arrival, same rule as purged files.
        if (purgedFolders.contains(op.targetId)) break;
        if (folders.containsKey(op.targetId)) break;
        folders[op.targetId] = FolderState(
          name: op.name ?? op.targetId,
          parentId: liveFolderOrRoot(op.folderId),
          deleted: false,
        );
      case SyncOpKind.moveFolder:
        final folder = folders[op.targetId];
        if (folder == null || folder.deleted) break;
        final newParent = liveFolderOrRoot(op.folderId);
        // Kleppmann rule: a move that would create a cycle at this point in
        // the fold is skipped. The order is global, so every device skips
        // the same op — deterministic, no reconciliation needed. The skip
        // is REPORTED so the losing device can tell its user.
        if (wouldCycle(op.targetId, newParent)) {
          skippedFolderMoves.add(op.opKey);
          break;
        }
        folders[op.targetId] = folder.copyWith(parentId: () => newParent);
      case SyncOpKind.renameFolder:
        // LWW by fold order; delete wins (a rename of a binned folder is
        // dropped) — mirrors renameFile.
        final folder = folders[op.targetId];
        if (folder != null && !folder.deleted && op.name != null) {
          folders[op.targetId] = folder.copyWith(name: op.name);
        }
      case SyncOpKind.setFolderHidden:
        // LWW by fold order; delete wins (a hide of a binned folder is
        // dropped); purged/unknown id is a no-op — mirrors renameFolder.
        // The flag rides copyWith untouched through deleteFolder cascades,
        // restoreFolder and moveFolder, and dies with the row on purgeFolder.
        final folder = folders[op.targetId];
        if (folder != null && !folder.deleted && op.favorite != null) {
          folders[op.targetId] = folder.copyWith(hidden: op.favorite);
        }
      case SyncOpKind.deleteFolder:
        final subtree = liveSubtreeOf(op.targetId);
        if (subtree.isEmpty) {
          // Target already binned by a concurrent cascade: re-stamp it as
          // an INDEPENDENT bin entry (cause null), so restoring the outer
          // folder cannot revive it against this explicit delete — the
          // folder-shaped twin of the deleteFile re-stamp above. Its own
          // cascade descendants keep their original cause and follow the
          // outer restore.
          final target = folders[op.targetId];
          if (target != null && target.deleted) {
            folders[op.targetId] = target.copyWith(
              deletedByFolderId: () => null,
              tombstoneWall: () => op.hlc.wallMs,
            );
          }
          break;
        }
        for (final id in subtree) {
          folders[id] = folders[id]!.copyWith(
            deleted: true,
            // The TARGETED folder is the bin entry (cause null); every
            // cascade-deleted descendant records the targeted ROOT.
            deletedByFolderId: () =>
                id == op.targetId ? null : op.targetId,
            tombstoneWall: () => op.hlc.wallMs,
          );
        }
        for (final e in files.entries.toList()) {
          final f = e.value;
          if (!f.deleted &&
              f.folderId != null &&
              subtree.contains(f.folderId)) {
            files[e.key] = f.copyWith(
              deleted: true,
              deletedByFolderId: () => op.targetId,
              tombstoneWall: () => op.hlc.wallMs,
            );
          }
        }
      case SyncOpKind.restoreFolder:
        // Model A: un-delete the folder as a UNIT — the folder itself plus
        // exactly the items its own cascade binned (cause == target). A
        // file individually deleted BEFORE the folder delete carries a null
        // cause and stays in the bin; a file individually restored earlier
        // had its cause cleared and is untouched. A concurrent foreign
        // deleteFolder with a later HLC re-deletes — converged either way.
        final folder = folders[op.targetId];
        if (folder == null || !folder.deleted) break;
        folders[op.targetId] = folder.copyWith(
          deleted: false,
          deletedByFolderId: () => null,
          tombstoneWall: () => null,
        );
        for (final e in folders.entries.toList()) {
          if (e.value.deleted &&
              e.value.deletedByFolderId == op.targetId) {
            folders[e.key] = e.value.copyWith(
              deleted: false,
              deletedByFolderId: () => null,
              tombstoneWall: () => null,
            );
          }
        }
        for (final e in files.entries.toList()) {
          if (e.value.deleted &&
              e.value.deletedByFolderId == op.targetId) {
            files[e.key] = e.value.copyWith(
              deleted: false,
              deletedByFolderId: () => null,
              tombstoneWall: () => null,
            );
          }
        }
      case SyncOpKind.purgeFolder:
        // Terminal removal of the folder ENTITY, inline (see purgedFolders
        // note above). Contained files are purged by their own explicit
        // purgeFile ops recorded by the bin action — never derived here.
        // Cascade causes pointing at a purged folder are left as-is: the
        // bin displays such leftovers (an interrupted purge batch)
        // individually, and the cause still names a real deleteFolder in
        // history, which is what the bin-cause invariant checks.
        purgedFolders.add(op.targetId);
        folders.remove(op.targetId);
      case SyncOpKind.registerDevice:
        devices[op.targetId] = op.name ?? op.targetId;
      case SyncOpKind.unknown:
        // Forward-compat: an op from a newer app version. Preserved in the
        // log verbatim (rawKind), meaningless to this build's fold — the
        // upgrade re-replays it with full meaning.
        break;
    }
  }

  // Terminal purge: forget purged files entirely — no row, no tombstone.
  // Every device that has the purge op reaches the same result, so the
  // 30-day bin sweep converges (no old-swept vs fresh-rebuilt divergence).
  for (final id in purged) {
    files.remove(id);
  }

  return VaultState(
    files: files,
    folders: folders,
    devices: devices,
    skippedFolderMoves: skippedFolderMoves,
  );
}
