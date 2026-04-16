import 'package:flutter/material.dart';
import '../../config/theme.dart';
import '../../models/album_model.dart';
import '../../models/file_model.dart';
import '../../../services/database_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/auto_sync_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/sync_service.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
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
    SyncService().syncNotifier.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    SyncService().syncNotifier.removeListener(_reload);
    super.dispose();
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All photos are already in this album')),
        );
      }
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
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Removed from album')),
      );
    }
  }

  Future<void> _handleDelete(CnestFile file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Photo?'),
        content: const Text('This will permanently delete the file from your vault.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      if (file.cloudId != null) await CloudService().deleteFile(file.cloudId!);
      if (file.thumbnailCloudId != null) {
        await CloudService().deleteFile(file.thumbnailCloudId!);
      }
      await DatabaseService().deleteFile(file.id);
      AutoSyncService.trackDeletion(file.filename, file.sizeBytes);
      DatabaseBackupService().scheduleBackup();

      final tempDir = await getTemporaryDirectory();
      for (final path in [
        '${tempDir.path}/thumb_${file.cloudId}.jpg',
        '${tempDir.path}/${file.cloudId}_decrypted.jpg',
        '${tempDir.path}/${file.id}_decrypted.mp4',
      ]) {
        final f = File(path);
        if (await f.exists()) await f.delete();
      }

      _reload();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Photo deleted')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  Future<void> _showOptions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.white),
              title: const Text('Rename Album', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.redAccent),
              title: const Text('Delete Album', style: TextStyle(color: Colors.redAccent)),
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
                child: const Text('Delete', style: TextStyle(color: Colors.red))),
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
        title: Text(widget.album.name),
        actions: [
          if (!widget.album.isSmart) ...[
            IconButton(icon: const Icon(Icons.add_photo_alternate), onPressed: _addPhotos),
            IconButton(icon: const Icon(Icons.more_vert), onPressed: _showOptions),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? const Center(
                  child: Text('No photos in this album',
                      style: TextStyle(color: Colors.grey)))
              : GridView.builder(
                  padding: EdgeInsets.zero,
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
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
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.remove_circle_outline, color: Colors.orangeAccent),
              title: const Text('Remove from Album', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.redAccent),
              title: const Text('Delete from Vault', style: TextStyle(color: Colors.redAccent)),
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
                        _selected.isEmpty ? Colors.grey : AppColors.primary,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: GridView.builder(
        padding: EdgeInsets.zero,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
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
                          isSelected ? AppColors.primary : Colors.black38,
                      border:
                          Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: isSelected
                        ? const Icon(Icons.check,
                            size: 16, color: Colors.white)
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
