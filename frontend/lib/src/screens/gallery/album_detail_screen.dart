import 'package:flutter/material.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';
import '../../models/album_model.dart';
import '../../models/file_model.dart';
import '../../../services/database_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/auto_sync_service.dart';
import '../../../services/sync_service.dart';
import '../../../services/notify.dart';
import 'pictures_tab.dart';
import 'image_viewer_screen.dart';

class AlbumDetailScreen extends StatefulWidget {
  final CnestAlbum album;
  const AlbumDetailScreen({super.key, required this.album});

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  List<CnestFile> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    SyncService().syncNotifier.addListener(_onNotify);
    // Rebuild the album's file grid when any file is deleted or restored
    // anywhere in the app (e.g. from Gallery view). getFilesForAlbum now
    // filters is_deleted so the removed row drops out automatically.
    DatabaseService().addListener(_onNotify);
    _reload();
  }

  @override
  void dispose() {
    SyncService().syncNotifier.removeListener(_onNotify);
    DatabaseService().removeListener(_onNotify);
    super.dispose();
  }

  void _onNotify() {
    if (mounted) _reload();
  }

  Future<void> _reload() async {
    final files = await DatabaseService().getFilesForAlbum(widget.album);
    if (mounted) setState(() { _files = files; _loading = false; });
  }

  Future<void> _addPhotos() async {
    // Load all vault images for picking
    final allFiles =
        await DatabaseService().getFilesByType(CnestFileType.image);
    final existingIds = _files.map((f) => f.id).toSet();
    final available =
        allFiles.where((f) => !existingIds.contains(f.id)).toList();

    if (available.isEmpty) {
      Notify.info('All photos are already in this album');
      return;
    }

    if (!mounted) return;
    final selected = await Navigator.push<List<CnestFile>>(
      context,
      MaterialPageRoute(
        builder: (_) => _VaultPhotoPicker(files: available),
      ),
    );

    if (selected == null || selected.isEmpty) return;

    await DatabaseService().addFilesToAlbum(
      widget.album.id,
      selected.map((f) => f.id).toList(),
    );
    _reload();
  }

  Future<void> _removeFromAlbum(CnestFile file) async {
    await DatabaseService().removeFileFromAlbum(widget.album.id, file.id);
    _reload();
    Notify.info('Removed from album');
  }

  Future<void> _handleDelete(CnestFile file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move to Recycle Bin?'),
        content: const Text(
          'The photo will be hidden here and everywhere else in the vault. '
          'You can restore it from Recycle Bin for the next 30 days.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Delete',
                  style:
                      TextStyle(color: ThemeController().tokens.danger))),
        ],
      ),
    );
    if (confirm != true) return;

    // Soft-delete only. The cloud blob survives so Recycle Bin can restore
    // instantly; the 30-day sweeper (recycle_bin_service.dart) is what
    // eventually purges the ciphertext. DatabaseService.deleteFile also
    // wipes the local cache and bumps notifyListeners, so this screen
    // rebuilds without a pull-to-refresh.
    try {
      await DatabaseService().deleteFile(file.id);
      AutoSyncService.trackDeletion(file.filename, file.sizeBytes);
      DatabaseBackupService().scheduleBackup();

      _reload();
      Notify.info('Moved to Recycle Bin');
    } catch (e) {
      Notify.error('Delete failed: $e');
    }
  }

  Future<void> _showOptions() async {
    final cs = Theme.of(context).colorScheme;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: cs.surface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: ThemeIcon('pencilSimple', color: cs.onSurface),
              title: Text('Rename Album', style: TextStyle(color: cs.onSurface)),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: ThemeIcon('trash', color: cs.error),
              title: Text('Delete Album', style: TextStyle(color: cs.error)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );

    if (action == 'rename') {
      final newName = await showDialog<String>(
        context: context,
        builder: (ctx) {
          final controller = TextEditingController(text: widget.album.name);
          return AlertDialog(
            title: const Text('Rename Album'),
            content: TextField(controller: controller, autofocus: true),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                  child: const Text('Save')),
            ],
          );
        },
      );
      if (newName != null && newName.isNotEmpty) {
        await DatabaseService().renameAlbum(widget.album.id, newName);
        if (mounted) Navigator.pop(context);
      }
    } else if (action == 'delete') {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete Album?'),
          content: const Text('Photos will remain in your vault. Only the album is removed.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('Delete',
                    style:
                        TextStyle(color: ThemeController().tokens.danger))),
          ],
        ),
      );
      if (confirm == true) {
        await DatabaseService().deleteAlbum(widget.album.id);
        if (mounted) Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.album.name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (!widget.album.isSmart) ...[
            IconButton(icon: ThemeIcon('imageSquare'), onPressed: _addPhotos),
            IconButton(icon: ThemeIcon('dotsThreeVertical'), onPressed: _showOptions),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? Center(
                  child: Text('No photos in this album',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withAlpha(120))))
              : GridView.builder(
                  padding: EdgeInsets.zero,
                  // 137 is load-bearing: full-bleed 411/138.5 -> 3 columns
                  // (same as before), 320 -> 3, 891 landscape -> 7.
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 137,
                    crossAxisSpacing: 1.5,
                    mainAxisSpacing: 1.5,
                  ),
                  itemCount: _files.length,
                  itemBuilder: (context, index) {
                    final file = _files[index];
                    return GestureDetector(
                      onTap: () async {
                        final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ImageViewerScreen(
                              files: _files,
                              initialIndex: index,
                            ),
                          ),
                        );
                        if (result == true) _reload();
                      },
                      onLongPress: () {
                        if (widget.album.isSmart) {
                          _handleDelete(file);
                        } else {
                          _showItemOptions(file);
                        }
                      },
                      child: GalleryGridItem(
                          key: ValueKey(file.id), file: file),
                    );
                  },
                ),
    );
  }

  Future<void> _showItemOptions(CnestFile file) async {
    final cs = Theme.of(context).colorScheme;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: cs.surface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: ThemeIcon('minusCircle', color: cs.primary),
              title: Text('Remove from Album', style: TextStyle(color: cs.onSurface)),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
            ListTile(
              leading: ThemeIcon('trash', color: cs.error),
              title: Text('Delete from Vault', style: TextStyle(color: cs.error)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'remove') {
      _removeFromAlbum(file);
    } else if (action == 'delete') {
      _handleDelete(file);
    }
  }
}

// --- Vault photo picker for adding photos to custom albums ---
class _VaultPhotoPicker extends StatefulWidget {
  final List<CnestFile> files;
  const _VaultPhotoPicker({required this.files});

  @override
  State<_VaultPhotoPicker> createState() => _VaultPhotoPickerState();
}

class _VaultPhotoPickerState extends State<_VaultPhotoPicker> {
  final Set<int> _selected = {};

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return Scaffold(
      appBar: AppBar(
        title: Text('${_selected.length} selected'),
        actions: [
          TextButton(
            onPressed: _selected.isEmpty
                ? null
                : () {
                    final picked =
                        _selected.map((i) => widget.files[i]).toList();
                    Navigator.pop(context, picked);
                  },
            child: Text('Add',
                style: TextStyle(
                    color:
                        _selected.isEmpty ? cs.onSurface.withAlpha(120) : cs.primary,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: GridView.builder(
        padding: EdgeInsets.zero,
        // 137 keeps 3 columns at 411 (and 320), 7 in 891 landscape.
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 137,
          mainAxisSpacing: 1.5,
          crossAxisSpacing: 1.5,
        ),
        itemCount: widget.files.length,
        itemBuilder: (context, index) {
          final isSelected = _selected.contains(index);
          return GestureDetector(
            onTap: () {
              setState(() {
                if (isSelected) {
                  _selected.remove(index);
                } else {
                  _selected.add(index);
                }
              });
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                GalleryGridItem(
                    key: ValueKey(widget.files[index].id),
                    file: widget.files[index]),
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color:
                          isSelected ? cs.primary : t.hairline,
                      border:
                          Border.all(color: cs.onSurface, width: 1.5),
                    ),
                    child: isSelected
                        ? ThemeIcon('check', selected: true,
                            size: 16, color: cs.onPrimary)
                        : null,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
