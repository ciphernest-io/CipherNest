/// A virtual-tree folder row — the materialized view of the op-log's
/// folder state (see SyncEngine.applyMergedState). Rows exist for deleted
/// folders too (the Recycle Bin shows them); only a purge removes one.
class CnestFolder {
  final String id;
  final String name;
  final String? parentId;
  final bool isDeleted;
  final DateTime? deletedAt;

  /// Cascade cause: the targeted root of the deleteFolder whose cascade
  /// binned this folder; null = deleted directly (its own bin entry) or
  /// live.
  final String? deletedByFolderId;
  final DateTime? createdAt;

  /// True for the auto-sync "Phone Backup" tree. Derived from the id
  /// prefix (see SystemFolders) and stamped by applyMergedState, so it
  /// converges with the id itself.
  final bool isSystem;

  /// The folder's OWN "hide from specialized views" flag (synced,
  /// setFolderHidden op). The menu toggle reads this.
  final bool isHidden;

  /// Own flag OR any ancestor's — the materialized subtree flag the
  /// specialized-view queries filter on. Display cues read this.
  final bool hiddenEffective;

  const CnestFolder({
    required this.id,
    required this.name,
    required this.parentId,
    required this.isDeleted,
    this.deletedAt,
    this.deletedByFolderId,
    this.createdAt,
    this.isSystem = false,
    this.isHidden = false,
    this.hiddenEffective = false,
  });

  factory CnestFolder.fromMap(Map<String, dynamic> map) => CnestFolder(
        id: map['id'] as String,
        name: map['name'] as String,
        parentId: map['parent_id'] as String?,
        isDeleted: (map['is_deleted'] as int? ?? 0) == 1,
        deletedAt: map['deleted_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(map['deleted_at'] as int),
        deletedByFolderId: map['deleted_by_folder_id'] as String?,
        createdAt: map['created_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
        isSystem: (map['is_system'] as int? ?? 0) == 1,
        isHidden: (map['is_hidden'] as int? ?? 0) == 1,
        hiddenEffective: (map['hidden_effective'] as int? ?? 0) == 1,
      );
}
