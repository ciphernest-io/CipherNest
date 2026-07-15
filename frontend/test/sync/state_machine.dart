/// Single-timeline semantics of CipherNest metadata actions — the meaning
/// of each user action when there is NO concurrency. Reference engines
/// reuse this so all of them agree on what actions mean; the production
/// engine must reduce to exactly these semantics in the sequential case.
///
/// Semantics (locked to the approved Plan 2 design):
///  * delete is SOFT: live -> binned (Recycle Bin). Deleting binned/unknown
///    is a no-op.
///  * edits (rename/move/favorite) apply to live files only — delete wins.
///  * folder delete recursively bins every live file in its subtree and
///    removes the subtree's folders.
///  * moves/creates targeting a nonexistent folder land at root (the
///    orphan-reparent rule).
library;

import 'sim_model.dart';

class StateMachine {
  final Map<String, FileMeta> live = {};
  final Map<String, FileMeta> binned = {};
  final Map<String, FolderMeta> folders = {};

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
        if (f != null) binned[a.targetId] = f;
      case ActionKind.restoreFile:
        final f = binned.remove(a.targetId);
        if (f != null) live[a.targetId] = f;
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
        folders[a.targetId] = FolderMeta(
          name: a.name ?? a.targetId,
          parentId:
              a.folderId != null && folders.containsKey(a.folderId)
                  ? a.folderId
                  : null,
        );
      case ActionKind.deleteFolder:
        final subtree = _subtreeOf(a.targetId);
        if (subtree.isEmpty) return;
        for (final id in subtree) {
          folders.remove(id);
        }
        final toBin = live.entries
            .where((e) =>
                e.value.folderId != null && subtree.contains(e.value.folderId))
            .map((e) => e.key)
            .toList();
        for (final id in toBin) {
          binned[id] = live.remove(id)!;
        }
    }
  }

  String? _existingFolderOrRoot(String? folderId) =>
      folderId != null && folders.containsKey(folderId) ? folderId : null;

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
        live: Map.of(live),
        binned: Map.of(binned),
        folders: Map.of(folders),
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
  }
}
