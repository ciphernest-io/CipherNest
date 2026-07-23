import 'package:flutter/material.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';

import '../../../services/cache_manager_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/database_service.dart';
import '../../../services/recycle_bin_service.dart';
import '../../models/file_model.dart';
import '../../models/folder_model.dart';
import '../gallery/image_viewer_screen.dart';
import '../gallery/pictures_tab.dart' show GalleryGridItem;
import 'folder_bin_detail_screen.dart';

const Duration kBinTtl = Duration(days: 30);

/// Whole days remaining before an entry deleted at [deletedAtMs] is
/// auto-purged.
int binDaysLeft(int? deletedAtMs) {
  if (deletedAtMs == null) return kBinTtl.inDays;
  final expiresAt =
      DateTime.fromMillisecondsSinceEpoch(deletedAtMs).add(kBinTtl);
  final diff = expiresAt.difference(DateTime.now()).inHours;
  if (diff <= 0) return 0;
  return (diff / 24).ceil();
}

/// The Model A folder-restore confirmation. Copy is deliberate and
/// user-mandated: the semantics must be predictable from the dialog alone.
Future<bool> confirmRestoreFolder(
    BuildContext context, CnestFolder folder) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Restore "${folder.name}"?'),
      content: const Text(
          'Restores this folder and the items removed with it. '
          'Items you deleted individually stay deleted.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore')),
      ],
    ),
  );
  return ok == true;
}

Future<bool> confirmPurgeFolder(
    BuildContext context, CnestFolder folder, int itemCount) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Delete "${folder.name}" forever?'),
      content: Text(
          'The folder and its $itemCount item${itemCount == 1 ? '' : 's'} '
          'are permanently deleted everywhere. This cannot be undone.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text('Delete forever',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Original-location breadcrumb, Windows-style. Segments that are
/// themselves deleted render greyed (decided: grey, no "(deleted)" suffix —
/// drill-in disambiguates). Pass the folder id the item LIVED in.
class FolderPathText extends StatelessWidget {
  final String? folderId;
  final double fontSize;
  const FolderPathText({super.key, required this.folderId, this.fontSize = 12});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (folderId == null) {
      return Text('My Vault',
          style: TextStyle(
              color: cs.onSurface.withAlpha(140), fontSize: fontSize));
    }
    return FutureBuilder<List<CnestFolder>>(
      future: DatabaseService().getFolderPathSegments(folderId!),
      builder: (context, snap) {
        final segments = snap.data ?? const <CnestFolder>[];
        if (segments.isEmpty) return const SizedBox.shrink();
        final normal = cs.onSurface.withAlpha(140);
        final greyed = cs.onSurface.withAlpha(70);
        return Text.rich(
          TextSpan(children: [
            for (var i = 0; i < segments.length; i++) ...[
              if (i > 0)
                TextSpan(
                    text: ' / ', style: TextStyle(color: normal)),
              TextSpan(
                text: segments[i].name,
                style: TextStyle(
                    color: segments[i].isDeleted ? greyed : normal),
              ),
            ],
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: fontSize),
        );
      },
    );
  }
}

/// Recycle Bin — five tabs mirroring the home grid. Folders first: a
/// deleted folder is ONE entry with an item count; its cascade contents
/// never flood the type tabs. Type tabs show individually-deleted files
/// (plus orphans whose cause folder is gone).
class RecycleBinScreen extends StatefulWidget {
  const RecycleBinScreen({super.key});

  @override
  State<RecycleBinScreen> createState() => _RecycleBinScreenState();
}

class _RecycleBinScreenState extends State<RecycleBinScreen> {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Recycle Bin'),
          actions: [
            IconButton(
              tooltip: 'Search the bin',
              icon: const ThemeIcon('list'),
              onPressed: () =>
                  showSearch(context: context, delegate: _BinSearchDelegate()),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Folders'),
              Tab(text: 'Photos & Videos'),
              Tab(text: 'Documents'),
              Tab(text: 'Music'),
              Tab(text: 'Other'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _FoldersBinTab(),
            _FilesBinTab(type: CnestFileType.image, noun: 'photo'),
            _FilesBinTab(type: CnestFileType.document, noun: 'document'),
            _FilesBinTab(type: CnestFileType.audio, noun: 'track'),
            _FilesBinTab(type: CnestFileType.other, noun: 'file'),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Folders tab
// ---------------------------------------------------------------------------

class _FoldersBinTab extends StatefulWidget {
  const _FoldersBinTab();

  @override
  State<_FoldersBinTab> createState() => _FoldersBinTabState();
}

class _FoldersBinTabState extends State<_FoldersBinTab> {
  List<CnestFolder> _folders = [];
  Map<String, int> _counts = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    DatabaseService().addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    DatabaseService().removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final folders = await DatabaseService().getDeletedFolders();
    final counts = await DatabaseService().getCascadeBinnedCounts();
    if (!mounted) return;
    setState(() {
      _folders = folders;
      _counts = counts;
      _loading = false;
    });
  }

  Future<void> _restore(CnestFolder folder) async {
    if (!await confirmRestoreFolder(context, folder)) return;
    await DatabaseService().restoreFolder(folder.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('"${folder.name}" restored')));
  }

  Future<void> _purge(CnestFolder folder) async {
    final count = _counts[folder.id] ?? 0;
    if (!await confirmPurgeFolder(context, folder, count)) return;
    final purged =
        await RecycleBinService().purgeFolderPermanently(folder.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('"${folder.name}" and $purged item'
            '${purged == 1 ? '' : 's'} permanently deleted')));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_folders.isEmpty) {
      return _emptyState(context, 'folder', 'No deleted folders');
    }
    return ListView.builder(
      itemCount: _folders.length,
      itemBuilder: (context, i) {
        final folder = _folders[i];
        final n = _counts[folder.id] ?? 0;
        final days =
            binDaysLeft(folder.deletedAt?.millisecondsSinceEpoch);
        return ListTile(
          leading: ThemeIcon('folder', color: cs.primary, size: 28),
          title: Text(folder.name,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FolderPathText(folderId: folder.parentId),
              Text('$n item${n == 1 ? '' : 's'} · ${days}d left',
                  style: TextStyle(
                      color: cs.onSurface.withAlpha(140), fontSize: 12)),
            ],
          ),
          isThreeLine: true,
          trailing: PopupMenuButton<String>(
            icon: const ThemeIcon('dotsThreeVertical'),
            onSelected: (v) => switch (v) {
              'restore' => _restore(folder),
              'purge' => _purge(folder),
              _ => null,
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'restore', child: Text('Restore')),
              PopupMenuItem(value: 'purge', child: Text('Delete forever')),
            ],
          ),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => FolderBinDetailScreen(folder: folder))),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// File tabs
// ---------------------------------------------------------------------------

class _FilesBinTab extends StatefulWidget {
  final CnestFileType type;
  final String noun;
  const _FilesBinTab({required this.type, required this.noun});

  @override
  State<_FilesBinTab> createState() => _FilesBinTabState();
}

class _FilesBinTabState extends State<_FilesBinTab> {
  List<CnestFile> _files = [];
  Map<String, int> _deletedAtById = {};
  bool _loading = true;
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    DatabaseService().addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    DatabaseService().removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final files = await DatabaseService().getDeletedFiles(type: widget.type);
    final deletedAt = <String, int>{};
    for (final f in files) {
      final ts = await DatabaseService().getDeletedAt(f.id);
      if (ts != null) deletedAt[f.id] = ts;
    }
    if (!mounted) return;
    setState(() {
      _files = files;
      _deletedAtById = deletedAt;
      _loading = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  Future<void> _restoreSelected() async {
    if (_selectedIds.isEmpty) return;
    final ids = List<String>.from(_selectedIds);
    for (final id in ids) {
      try {
        await DatabaseService().restoreFile(id);
      } catch (_) {}
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${ids.length} ${widget.noun}'
            '${ids.length == 1 ? '' : 's'} restored')));
    _exitSelection();
  }

  Future<void> _selectAll() {
    return Future.sync(() => setState(() {
          _selectionMode = true;
          _selectedIds
            ..clear()
            ..addAll(_files.map((f) => f.id));
        }));
  }

  Future<void> _deleteForeverSelected() async {
    final picked =
        _files.where((f) => _selectedIds.contains(f.id)).toList();
    if (picked.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${picked.length} ${widget.noun}'
            '${picked.length == 1 ? '' : 's'} forever?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete forever',
                style:
                    TextStyle(color: Theme.of(ctx).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    // Cloud + DB purge, then cache wipe through invalidateFile so its
    // ChangeNotifier fires and the Settings cache tile updates. A failed
    // cloud delete never blocks the purge: the purge tombstone condemns
    // the blob and the condemned-blob sweep retries until it lands.
    for (final f in picked) {
      try {
        if (f.cloudId != null) await CloudService().deleteFile(f.cloudId!);
      } catch (e) {
        debugPrint('Delete forever: blob delete failed (${f.cloudId}): $e');
      }
      try {
        if (f.thumbnailCloudId != null) {
          await CloudService().deleteFile(f.thumbnailCloudId!);
        }
      } catch (e) {
        debugPrint(
            'Delete forever: thumb delete failed (${f.thumbnailCloudId}): $e');
      }
      try {
        await DatabaseService().permanentlyDeleteFile(f.id);
      } catch (_) {}
      await CacheManagerService().invalidateFile(
        fileId: f.id,
        cloudId: f.cloudId,
        thumbnailCloudId: f.thumbnailCloudId,
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${picked.length} ${widget.noun}'
            '${picked.length == 1 ? '' : 's'} permanently deleted')));
    _exitSelection();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_files.isEmpty) {
      return _emptyState(context, 'trash', 'Nothing here');
    }
    return Column(
      children: [
        if (_selectionMode) _buildSelectionBar(),
        Expanded(child: _buildGrid()),
      ],
    );
  }

  Widget _buildSelectionBar() {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      bottom: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        color: cs.surfaceContainerHighest,
        child: Row(
          children: [
            IconButton(
                icon: const ThemeIcon('x'), onPressed: _exitSelection),
            const SizedBox(width: 4),
            Text('${_selectedIds.length} selected',
                style: TextStyle(
                    color: cs.onSurface, fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton(
              onPressed: _selectAll,
              child: const Text('All'),
            ),
            IconButton(
              tooltip: 'Restore',
              icon: const ThemeIcon('arrowCounterClockwise'),
              onPressed: _restoreSelected,
            ),
            IconButton(
              tooltip: 'Delete forever',
              icon: ThemeIcon('trashSimple', color: cs.error),
              onPressed: _deleteForeverSelected,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid() {
    final t = ThemeController().tokens;
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 1.5,
        mainAxisSpacing: 1.5,
      ),
      itemCount: _files.length,
      itemBuilder: (context, index) {
        final file = _files[index];
        final isSelected = _selectedIds.contains(file.id);
        final daysLeft = binDaysLeft(_deletedAtById[file.id]);
        return GestureDetector(
          onTap: () {
            if (_selectionMode) {
              setState(() {
                if (!_selectedIds.remove(file.id)) {
                  _selectedIds.add(file.id);
                }
                if (_selectedIds.isEmpty) _selectionMode = false;
              });
              return;
            }
            Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ImageViewerScreen(
                    files: _files, initialIndex: index)));
          },
          onLongPress: () => setState(() {
            _selectionMode = true;
            _selectedIds.add(file.id);
          }),
          child: Stack(
            fit: StackFit.expand,
            children: [
              GalleryGridItem(key: ValueKey(file.id), file: file),
              Positioned(
                top: 4,
                left: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: t.scrim,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${daysLeft}d left',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              if (_selectionMode)
                Container(
                  color: isSelected ? t.scrim : Colors.transparent,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: ThemeIcon(
                        isSelected
                            ? 'checkCircle'
                            : 'radio_button_unchecked',
                        selected: isSelected,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

Widget _emptyState(BuildContext context, String icon, String message) {
  final cs = Theme.of(context).colorScheme;
  return Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ThemeIcon(icon, size: 64, color: cs.onSurface.withAlpha(120)),
        const SizedBox(height: 12),
        Text(message,
            style: TextStyle(color: cs.onSurface.withAlpha(140))),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Bin search — finds cascade-binned files too and offers the folder restore
// ---------------------------------------------------------------------------

class _BinSearchDelegate extends SearchDelegate<void> {
  @override
  String get searchFieldLabel => 'Search deleted files';

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
              icon: const ThemeIcon('x'), onPressed: () => query = ''),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
      icon: const ThemeIcon('arrowLeft'),
      onPressed: () => close(context, null));

  @override
  Widget buildResults(BuildContext context) => _results(context);

  @override
  Widget buildSuggestions(BuildContext context) => _results(context);

  Widget _results(BuildContext context) {
    if (query.trim().isEmpty) return const SizedBox.shrink();
    return FutureBuilder<List<CnestFile>>(
      future: DatabaseService().searchDeletedFiles(query),
      builder: (context, snap) {
        final files = snap.data;
        if (files == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (files.isEmpty) {
          return _emptyState(context, 'trash', 'No deleted files match');
        }
        return ListView.builder(
          itemCount: files.length,
          itemBuilder: (context, i) => _BinSearchResultTile(file: files[i]),
        );
      },
    );
  }
}

class _BinSearchResultTile extends StatelessWidget {
  final CnestFile file;
  const _BinSearchResultTile({required this.file});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final cause = _causeFolderId();
    return ListTile(
      leading: SizedBox(
        width: 44,
        height: 44,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: GalleryGridItem(key: ValueKey(file.id), file: file),
        ),
      ),
      title: Text(file.filename,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: FolderPathText(folderId: file.folderId),
      trailing: cause != null
          ? _RestoreFolderCta(file: file, causeFolderId: cause)
          : TextButton(
              onPressed: () async {
                await DatabaseService().restoreFile(file.id);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('"${file.filename}" restored')));
                }
              },
              child: const Text('Restore'),
            ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) =>
              ImageViewerScreen(files: [file], initialIndex: 0))),
      textColor: cs.onSurface,
    );
  }

  /// A cascade-binned search hit belongs to a deleted folder — surface
  /// `Restore '<folder>'` as the primary action (the file's context comes
  /// back with it). Individually-deleted hits get a plain Restore.
  String? _causeFolderId() => file.deletedByFolderId;
}

/// Loads the cause folder (if any) for a binned file and renders the
/// primary `Restore '<folder>'` CTA with single-file restore secondary.
class _RestoreFolderCta extends StatelessWidget {
  final CnestFile file;
  final String causeFolderId;
  const _RestoreFolderCta(
      {required this.file, required this.causeFolderId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<CnestFolder>>(
      future: DatabaseService().getFolderPathSegments(causeFolderId),
      builder: (context, snap) {
        final folder =
            (snap.data?.isNotEmpty ?? false) ? snap.data!.last : null;
        if (folder == null) return const SizedBox.shrink();
        return TextButton(
          onPressed: () async {
            if (!await confirmRestoreFolder(context, folder)) return;
            await DatabaseService().restoreFolder(folder.id);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('"${folder.name}" restored')));
            }
          },
          child: Text('Restore "${folder.name}"',
              maxLines: 1, overflow: TextOverflow.ellipsis),
        );
      },
    );
  }
}
