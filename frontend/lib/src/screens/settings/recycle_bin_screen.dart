import 'package:flutter/material.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';

import '../../../services/cache_manager_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/database_service.dart';
import '../../models/file_model.dart';
import '../gallery/image_viewer_screen.dart';
import '../gallery/pictures_tab.dart' show GalleryGridItem;

/// Tuple of soft-deleted files plus a map of id -> deleted_at millis. We
/// load deleted_at separately because CnestFile doesn't carry it.
class _BinSnapshot {
  final List<CnestFile> files;
  final Map<String, int> deletedAtById;
  const _BinSnapshot(this.files, this.deletedAtById);
}

/// Recycle Bin — surfaces soft-deleted files for restore or permanent
/// deletion. Mirrors the pictures_tab grid + selection paradigm so users
/// don't have to learn a new gesture vocabulary here.
class RecycleBinScreen extends StatefulWidget {
  const RecycleBinScreen({super.key});

  @override
  State<RecycleBinScreen> createState() => _RecycleBinScreenState();
}

class _RecycleBinScreenState extends State<RecycleBinScreen> {
  late Future<_BinSnapshot> _filesFuture;
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  static const Duration _ttl = Duration(days: 30);

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _filesFuture = _loadSnapshot();
    });
  }

  Future<_BinSnapshot> _loadSnapshot() async {
    final files = await DatabaseService().getDeletedFiles();
    final deletedAt = <String, int>{};
    for (final f in files) {
      final ts = await DatabaseService().getDeletedAt(f.id);
      if (ts != null) deletedAt[f.id] = ts;
    }
    return _BinSnapshot(files, deletedAt);
  }

  void _enterSelection(String id) {
    setState(() {
      _selectionMode = true;
      _selectedIds.add(id);
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
      if (_selectedIds.isEmpty) _selectionMode = false;
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
      } catch (_) {
        // Silent — best effort.
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${ids.length} photo${ids.length == 1 ? '' : 's'} restored',
        ),
      ),
    );
    _exitSelection();
    _refresh();
  }

  Future<void> _deleteForeverSelected(List<CnestFile> all) async {
    final picked = all.where((f) => _selectedIds.contains(f.id)).toList();
    if (picked.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${picked.length} photo'
            '${picked.length == 1 ? '' : 's'} forever?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Delete forever',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    // Cloud + DB purge, then route cache wipe through
    // CacheManagerService.invalidateFile so its ChangeNotifier fires and
    // the Settings cache-size tile updates immediately after this action.
    // A failed cloud delete must not block the purge: the purge tombstone
    // condemns the blob, and the sync cycle's condemned-blob sweep retries
    // the deletion until it lands.
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${picked.length} photo${picked.length == 1 ? '' : 's'} '
          'permanently deleted',
        ),
      ),
    );
    _exitSelection();
    _refresh();
  }

  /// Whole days remaining before this file is auto-purged.
  int _daysLeft(CnestFile file, Map<String, int> deletedAtById) {
    final ms = deletedAtById[file.id];
    if (ms == null) return _ttl.inDays;
    final expiresAt =
        DateTime.fromMillisecondsSinceEpoch(ms).add(_ttl);
    final diff = expiresAt.difference(DateTime.now()).inHours;
    if (diff <= 0) return 0;
    return (diff / 24).ceil();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _selectionMode ? null : AppBar(title: const Text('Recycle Bin')),
      body: FutureBuilder<_BinSnapshot>(
        future: _filesFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final snap = snapshot.data!;
          if (snap.files.isEmpty) return _buildEmpty();

          return Column(
            children: [
              if (_selectionMode) _buildSelectionBar(snap.files),
              Expanded(child: _buildGrid(snap)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildEmpty() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ThemeIcon(
            'trash',
            size: 64,
            color: cs.onSurface.withAlpha(120),
          ),
          const SizedBox(height: 12),
          Text(
            'Recycle bin is empty',
            style: TextStyle(color: cs.onSurface.withAlpha(140)),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionBar(List<CnestFile> files) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      bottom: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        color: cs.surfaceContainerHighest,
        child: Row(
          children: [
            IconButton(
              icon: const ThemeIcon('x'),
              onPressed: _exitSelection,
            ),
            const SizedBox(width: 4),
            Text(
              '${_selectedIds.length} selected',
              style: TextStyle(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Restore',
              icon: const ThemeIcon('arrowCounterClockwise'),
              onPressed: _restoreSelected,
            ),
            IconButton(
              tooltip: 'Delete forever',
              icon: ThemeIcon(
                'trashSimple',
                color: cs.error,
              ),
              onPressed: () => _deleteForeverSelected(files),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(_BinSnapshot snap) {
    final t = ThemeController().tokens;
    final files = snap.files;
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 1.5,
        mainAxisSpacing: 1.5,
      ),
      itemCount: files.length,
      itemBuilder: (context, index) {
        final file = files[index];
        final isSelected = _selectedIds.contains(file.id);
        final daysLeft = _daysLeft(file, snap.deletedAtById);
        return GestureDetector(
          onTap: () {
            if (_selectionMode) {
              _toggleSelected(file.id);
              return;
            }
            // Open the standard viewer with the whole bin as the pageview
            // source, starting at this tile. Restoration + hard-delete
            // still route through this screen — the viewer is read-only
            // for Recycle Bin entries.
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ImageViewerScreen(
                  files: files,
                  initialIndex: index,
                ),
              ),
            );
          },
          onLongPress: () => _enterSelection(file.id),
          child: Stack(
            fit: StackFit.expand,
            children: [
              GalleryGridItem(key: ValueKey(file.id), file: file),
              Positioned(
                top: 4,
                left: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: t.scrim,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${daysLeft}d left',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              if (_selectionMode)
                Container(
                  color: isSelected
                      ? t.scrim
                      : Colors.transparent,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: ThemeIcon(
                        isSelected ? 'checkCircle' : 'radio_button_unchecked',
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
