import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/cloud/cloud_service.dart';
import '../../services/database_service.dart';
import '../../services/system_folders.dart';
import '../models/folder_model.dart';
import 'theme_icon.dart';

/// The picked destination. [folderId] null = root ("My Vault").
class FolderPickResult {
  final String? folderId;
  final String label;
  const FolderPickResult({required this.folderId, required this.label});
}

/// Bottom-sheet folder picker: root plus every live folder, indented by
/// depth. [excludeSubtreeOf] hides a folder and its descendants — a folder
/// can't be moved into itself (the same rule replay enforces globally; the
/// exclusion here is instant UX, not correctness).
Future<FolderPickResult?> showFolderPicker(
  BuildContext context, {
  String title = 'Move to folder',
  String? excludeSubtreeOf,
}) async {
  final all = await _allLiveFolders();
  if (!context.mounted) return null;

  final excluded = excludeSubtreeOf == null
      ? const <String>{}
      : _subtreeIds(all, excludeSubtreeOf);
  final entries = _flattenTree(all)
      .where((e) => !excluded.contains(e.folder.id))
      .toList();

  return showModalBottomSheet<FolderPickResult>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(title,
                    style: Theme.of(ctx).textTheme.titleMedium),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      leading: ThemeIcon('folderOpen', color: cs.primary),
                      title: const Text('My Vault'),
                      subtitle: Text('Top level',
                          style: TextStyle(
                              color: cs.onSurface.withAlpha(140),
                              fontSize: 12)),
                      onTap: () => Navigator.pop(
                          ctx,
                          const FolderPickResult(
                              folderId: null, label: 'My Vault')),
                    ),
                    for (final e in entries)
                      ListTile(
                        // Indent caps at depth 5 (116dp) so a deep tree
                        // still leaves room for the icon and name.
                        contentPadding: EdgeInsets.only(
                            left: 16.0 + math.min(e.depth, 5) * 20.0,
                            right: 16),
                        leading: ThemeIcon('folder', color: cs.primary),
                        title: Text(e.folder.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.pop(
                            ctx,
                            FolderPickResult(
                                folderId: e.folder.id,
                                label: e.folder.name)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}

class _TreeEntry {
  final CnestFolder folder;
  final int depth;
  const _TreeEntry(this.folder, this.depth);
}

Future<List<CnestFolder>> _allLiveFolders() async {
  // getFolders is per-parent; collect the whole live tree breadth-first.
  final out = <CnestFolder>[];
  final queue = <String?>[null];
  final seen = <String?>{};
  while (queue.isNotEmpty) {
    final parent = queue.removeAt(0);
    if (!seen.add(parent)) continue;
    final children = await DatabaseService().getFolders(parentId: parent);
    out.addAll(children);
    queue.addAll(children.map((f) => f.id));
  }
  // The hidden Album Covers folder is managed by the music screens; it must
  // never be an upload or move destination.
  final email = CloudService().currentEmail;
  if (email != null) {
    final coversId = SystemFolders.albumCoversId(email);
    out.removeWhere((f) => f.id == coversId);
  }
  return out;
}

Set<String> _subtreeIds(List<CnestFolder> all, String rootId) {
  final subtree = <String>{rootId};
  var grew = true;
  while (grew) {
    grew = false;
    for (final f in all) {
      if (!subtree.contains(f.id) &&
          f.parentId != null &&
          subtree.contains(f.parentId)) {
        subtree.add(f.id);
        grew = true;
      }
    }
  }
  return subtree;
}

List<_TreeEntry> _flattenTree(List<CnestFolder> all) {
  final byParent = <String?, List<CnestFolder>>{};
  for (final f in all) {
    byParent.putIfAbsent(f.parentId, () => []).add(f);
  }
  final out = <_TreeEntry>[];
  void walk(String? parent, int depth) {
    for (final f in byParent[parent] ?? const <CnestFolder>[]) {
      out.add(_TreeEntry(f, depth));
      walk(f.id, depth + 1);
    }
  }

  walk(null, 0);
  return out;
}
