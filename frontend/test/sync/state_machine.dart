/// Single-timeline semantics of CipherNest metadata actions — the meaning
/// of each user action when there is NO concurrency. Reference engines
/// reuse this so all of them agree on what actions mean; the production
/// engine must reduce to exactly these semantics in the sequential case.
///
/// Semantics (Plan 2 design + the Model A folder revision):
///  * delete is SOFT: live -> binned (Recycle Bin). Deleting binned/unknown
///    is a no-op.
///  * edits (rename/move/favorite) apply to live items only — delete wins.
///  * folder delete cascade-bins the live subtree; every binned item
///    records the TARGETED folder as its cause (the folder itself carries a
///    null cause — it is the bin entry). Items already binned keep their
///    own cause and are never absorbed.
///  * restoreFolder un-deletes the folder plus exactly its cause-matching
///    items (Model A: the folder comes back as a unit; individually-deleted
///    items stay deleted).
///  * purge is TERMINAL: gone from everywhere, unrecoverable. purgeFolder
///    removes only the folder ENTITY (contents are purged by their own
///    purgeFile actions); a purged folder id can never be re-created.
///  * moves/creates targeting a nonexistent folder land at root (the
///    orphan-reparent rule).
///  * NORMALIZATION happens at [snapshot], never in stored state: live
///    entries' folder pointers are resolved to live-or-root for the
///    materialized view, while stored state keeps the RAW pointer so a
///    child rejoins a later-restored parent. Binned entries expose raw
///    pointers (the bin shows original context).
library;

import 'sim_model.dart';

class StateMachine {
  final Map<String, FileMeta> live = {};
  final Map<String, FileMeta> binned = {};
  final Map<String, FolderMeta> folders = {};
  final Map<String, FolderMeta> binnedFolders = {};

  /// Terminality guard, mirroring replay: a straggler createFolder for a
  /// purged id is dead on arrival. (Not carried by [adopt] — reference
  /// engines that adopt snapshots are gated with includePurge:false.)
  final Set<String> _purgedFolders = {};

  void apply(LocalAction a) {
    switch (a.kind) {
      case ActionKind.createFile:
        // Creates are unique (uuid) — re-creating an existing id is a
        // generator bug, not a semantic case.
        live[a.targetId] = FileMeta(
          name: a.name ?? a.targetId,
          folderId: _existingFolderOrRoot(a.folderId),
          favorite: false,
        );
      case ActionKind.deleteFile:
        final f = live.remove(a.targetId);
        if (f != null) {
          binned[a.targetId] = f; // cause null: individual
        } else {
          final b = binned[a.targetId];
          if (b != null && b.deletedByFolder != null) {
            // Re-stamp a cascade-binned file as an INDIVIDUAL entry —
            // delete wins over a later restoreFolder (seed-178 lesson).
            binned[a.targetId] = FileMeta(
                name: b.name, folderId: b.folderId, favorite: b.favorite);
          }
        }
      case ActionKind.restoreFile:
        final f = binned.remove(a.targetId);
        if (f != null) {
          // Cause cleared; folderId kept RAW (rejoin rule).
          live[a.targetId] = FileMeta(
              name: f.name, folderId: f.folderId, favorite: f.favorite);
        }
      case ActionKind.purgeFile:
        // Terminal: gone from everywhere, unrecoverable.
        live.remove(a.targetId);
        binned.remove(a.targetId);
      case ActionKind.renameFile:
        final f = live[a.targetId];
        if (f != null) {
          live[a.targetId] = FileMeta(
              name: a.name ?? f.name,
              folderId: f.folderId,
              favorite: f.favorite);
        }
      case ActionKind.moveFile:
        final f = live[a.targetId];
        if (f != null) {
          live[a.targetId] = FileMeta(
              name: f.name,
              folderId: _existingFolderOrRoot(a.folderId),
              favorite: f.favorite);
        }
      case ActionKind.setFavorite:
        final f = live[a.targetId];
        if (f != null) {
          live[a.targetId] = FileMeta(
              name: f.name,
              folderId: f.folderId,
              favorite: a.favorite ?? f.favorite);
        }
      case ActionKind.createFolder:
        if (_purgedFolders.contains(a.targetId)) return;
        folders[a.targetId] = FolderMeta(
          name: a.name ?? a.targetId,
          parentId: _existingFolderOrRoot(a.folderId),
        );
      case ActionKind.moveFolder:
        final f = folders[a.targetId];
        if (f == null) return;
        final newParent = _existingFolderOrRoot(a.folderId);
        if (_wouldCycle(a.targetId, newParent)) return;
        folders[a.targetId] = FolderMeta(
            name: f.name,
            parentId: newParent,
            deletedByFolder: f.deletedByFolder);
      case ActionKind.renameFolder:
        final f = folders[a.targetId];
        if (f != null && a.name != null) {
          folders[a.targetId] = FolderMeta(
              name: a.name!,
              parentId: f.parentId,
              deletedByFolder: f.deletedByFolder);
        }
      case ActionKind.deleteFolder:
        final subtree = _subtreeOf(a.targetId);
        if (subtree.isEmpty) {
          // Folder twin of the deleteFile re-stamp: an explicit delete of
          // an already-cascade-binned folder makes it an independent bin
          // entry the outer folder's restore cannot revive.
          final b = binnedFolders[a.targetId];
          if (b != null && b.deletedByFolder != null) {
            binnedFolders[a.targetId] =
                FolderMeta(name: b.name, parentId: b.parentId);
          }
          return;
        }
        for (final id in subtree) {
          final f = folders.remove(id)!;
          binnedFolders[id] = FolderMeta(
            name: f.name,
            parentId: f.parentId,
            deletedByFolder: id == a.targetId ? null : a.targetId,
          );
        }
        final toBin = live.entries
            .where((e) =>
                e.value.folderId != null && subtree.contains(e.value.folderId))
            .map((e) => e.key)
            .toList();
        for (final id in toBin) {
          final f = live.remove(id)!;
          binned[id] = FileMeta(
            name: f.name,
            folderId: f.folderId,
            favorite: f.favorite,
            deletedByFolder: a.targetId,
          );
        }
      case ActionKind.restoreFolder:
        final f = binnedFolders.remove(a.targetId);
        if (f == null) return;
        folders[a.targetId] =
            FolderMeta(name: f.name, parentId: f.parentId);
        final folderIds = binnedFolders.entries
            .where((e) => e.value.deletedByFolder == a.targetId)
            .map((e) => e.key)
            .toList();
        for (final id in folderIds) {
          final g = binnedFolders.remove(id)!;
          folders[id] = FolderMeta(name: g.name, parentId: g.parentId);
        }
        final fileIds = binned.entries
            .where((e) => e.value.deletedByFolder == a.targetId)
            .map((e) => e.key)
            .toList();
        for (final id in fileIds) {
          final g = binned.remove(id)!;
          live[id] = FileMeta(
              name: g.name, folderId: g.folderId, favorite: g.favorite);
        }
      case ActionKind.purgeFolder:
        // Terminal removal of the folder ENTITY only; dangling causes on
        // leftover binned items are kept (they still name a real delete).
        folders.remove(a.targetId);
        binnedFolders.remove(a.targetId);
        _purgedFolders.add(a.targetId);
    }
  }

  String? _existingFolderOrRoot(String? folderId) =>
      folderId != null && folders.containsKey(folderId) ? folderId : null;

  bool _wouldCycle(String folderId, String? newParent) {
    var cursor = newParent;
    var hops = 0;
    while (cursor != null && hops++ < folders.length + 1) {
      if (cursor == folderId) return true;
      cursor = folders[cursor]?.parentId;
    }
    return false;
  }

  Set<String> _subtreeOf(String rootId) {
    if (!folders.containsKey(rootId)) return const {};
    final subtree = <String>{rootId};
    var grew = true;
    while (grew) {
      grew = false;
      for (final e in folders.entries) {
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

  MaterializedState snapshot() => MaterializedState(
        live: {
          for (final e in live.entries)
            e.key: FileMeta(
              name: e.value.name,
              folderId: folders.containsKey(e.value.folderId)
                  ? e.value.folderId
                  : null,
              favorite: e.value.favorite,
            ),
        },
        binned: Map.of(binned),
        folders: {
          for (final e in folders.entries)
            e.key: FolderMeta(
              name: e.value.name,
              parentId: folders.containsKey(e.value.parentId)
                  ? e.value.parentId
                  : null,
            ),
        },
        binnedFolders: Map.of(binnedFolders),
      );

  void adopt(MaterializedState s) {
    live
      ..clear()
      ..addAll(s.live);
    binned
      ..clear()
      ..addAll(s.binned);
    folders
      ..clear()
      ..addAll(s.folders);
    binnedFolders
      ..clear()
      ..addAll(s.binnedFolders);
  }
}
