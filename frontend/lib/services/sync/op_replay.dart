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
///    unknown folders materialize at root.
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

  const FileState({
    required this.name,
    required this.folderId,
    required this.favorite,
    required this.deleted,
  });

  FileState copyWith({
    String? name,
    String? Function()? folderId,
    bool? favorite,
    bool? deleted,
  }) =>
      FileState(
        name: name ?? this.name,
        folderId: folderId != null ? folderId() : this.folderId,
        favorite: favorite ?? this.favorite,
        deleted: deleted ?? this.deleted,
      );
}

class FolderState {
  final String name;
  final String? parentId;
  final bool deleted;

  const FolderState({
    required this.name,
    required this.parentId,
    required this.deleted,
  });

  FolderState copyWith({
    String? name,
    String? Function()? parentId,
    bool? deleted,
  }) =>
      FolderState(
        name: name ?? this.name,
        parentId: parentId != null ? parentId() : this.parentId,
        deleted: deleted ?? this.deleted,
      );
}

class VaultState {
  final Map<String, FileState> files;
  final Map<String, FolderState> folders;
  final Map<String, String> devices; // deviceId -> display name

  const VaultState({
    required this.files,
    required this.folders,
    required this.devices,
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
          );
        } else if (!f.deleted) {
          files[op.targetId] = f.copyWith(deleted: true);
        }
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
        // the same op — deterministic, no reconciliation needed.
        if (wouldCycle(op.targetId, newParent)) break;
        folders[op.targetId] = folder.copyWith(parentId: () => newParent);
      case SyncOpKind.deleteFolder:
        final subtree = liveSubtreeOf(op.targetId);
        if (subtree.isEmpty) break;
        for (final id in subtree) {
          folders[id] = folders[id]!.copyWith(deleted: true);
        }
        for (final e in files.entries.toList()) {
          final f = e.value;
          if (!f.deleted &&
              f.folderId != null &&
              subtree.contains(f.folderId)) {
            files[e.key] = f.copyWith(deleted: true);
          }
        }
      case SyncOpKind.registerDevice:
        devices[op.targetId] = op.name ?? op.targetId;
    }
  }

  return VaultState(files: files, folders: folders, devices: devices);
}
