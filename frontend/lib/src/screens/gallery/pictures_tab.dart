import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../config/theme.dart';
import '../../models/file_model.dart';
import '../../utils/date_grouper.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/database_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/auto_sync_service.dart';
import '../../../services/sync_service.dart';
import 'image_viewer_screen.dart';

class PicturesTab extends StatefulWidget {
  const PicturesTab({super.key});

  @override
  State<PicturesTab> createState() => PicturesTabState();
}

class PicturesTabState extends State<PicturesTab> {
  late Future<List<CnestFile>> _filesFuture;

  @override
  void initState() {
    super.initState();
    SyncService().syncNotifier.addListener(_onSyncComplete);
    _refresh();
  }

  @override
  void dispose() {
    SyncService().syncNotifier.removeListener(_onSyncComplete);
    super.dispose();
  }

  void _onSyncComplete() {
    if (mounted) _refresh();
  }

  void refresh() => _refresh();

  void _refresh() {
    setState(() {
      _filesFuture = DatabaseService().getFilesByType(CnestFileType.image);
    });
  }

  Future<void> handleSync() async {
    await SyncService().syncNow(force: true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sync complete')),
      );
    }
  }

  Future<void> _handleDelete(CnestFile file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Photo?'),
        content: const Text('This will permanently delete the file.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('Delete', style: TextStyle(color: Colors.red))),
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
        '${tempDir.path}/${file.id}_thumb.jpg',
        '${tempDir.path}/${file.id}.cnest_decrypted',
      ]) {
        final f = File(path);
        if (await f.exists()) await f.delete();
      }

      _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Photo deleted')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<CnestFile>>(
      future: _filesFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final files = snapshot.data!;

        if (files.isEmpty) {
          return RefreshIndicator(
            onRefresh: handleSync,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 300),
                Center(
                    child: Text('No encrypted photos yet.\nPull to sync.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey))),
              ],
            ),
          );
        }

        final sections = groupByDate(files);

        // Build a flat list for ImageViewerScreen navigation
        final flatFiles = files;

        return RefreshIndicator(
          onRefresh: handleSync,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              for (int s = 0; s < sections.length; s++) ...[
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _DateHeaderDelegate(sections[s].label),
                ),
                SliverGrid(
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 1.5,
                    mainAxisSpacing: 1.5,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final file = sections[s].files[index];
                      // Compute global index for ImageViewerScreen
                      int globalIndex = 0;
                      for (int prev = 0; prev < s; prev++) {
                        globalIndex += sections[prev].files.length;
                      }
                      globalIndex += index;

                      return GestureDetector(
                        onTap: () async {
                          final result = await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ImageViewerScreen(
                                files: flatFiles,
                                initialIndex: globalIndex,
                              ),
                            ),
                          );
                          if (result == true) _refresh();
                        },
                        onLongPress: () => _handleDelete(file),
                        child: GalleryGridItem(
                            key: ValueKey(file.id), file: file),
                      );
                    },
                    childCount: sections[s].files.length,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _DateHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String label;
  _DateHeaderDelegate(this.label);

  @override
  double get minExtent => 36;
  @override
  double get maxExtent => 36;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: AppColors.background,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          fontFamily: 'Inter',
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _DateHeaderDelegate oldDelegate) =>
      label != oldDelegate.label;
}

/// Shared thumbnail grid item — used by Pictures tab, Albums detail, etc.
class GalleryGridItem extends StatefulWidget {
  final CnestFile file;
  const GalleryGridItem({super.key, required this.file});

  @override
  State<GalleryGridItem> createState() => _GalleryGridItemState();
}

class _GalleryGridItemState extends State<GalleryGridItem> {
  Uint8List? _imageData;
  bool _loading = true;
  bool _isVideo = false;

  @override
  void initState() {
    super.initState();
    final ext = widget.file.filename.split('.').last.toLowerCase();
    _isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(ext);
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    if (!mounted) return;

    // LOCAL-FIRST: If the original exists on device, use it directly (no decryption).
    // Skip for videos — generating a thumbnail from a local video per grid item is too expensive.
    if (!_isVideo && widget.file.localPath != null) {
      final localFile = File(widget.file.localPath!);
      if (await localFile.exists()) {
        final bytes = await localFile.readAsBytes();
        if (mounted) setState(() { _imageData = bytes; _loading = false; });
        return;
      }
    }

    // CLOUD FALLBACK: download encrypted thumbnail, decrypt, cache
    if (_isVideo && widget.file.thumbnailCloudId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    try {
      final cacheDir = await getTemporaryDirectory();
      final targetCloudId =
          widget.file.thumbnailCloudId ?? widget.file.cloudId;
      if (targetCloudId == null) throw Exception("No ID");

      final isThumbnail = widget.file.thumbnailCloudId != null;
      final fileName = isThumbnail
          ? 'thumb_${widget.file.cloudId}.jpg'
          : '${widget.file.cloudId}_decrypted.jpg';
      final cacheFile = File('${cacheDir.path}/$fileName');

      if (await cacheFile.exists()) {
        final bytes = await cacheFile.readAsBytes();
        if (mounted) setState(() { _imageData = bytes; _loading = false; });
        return;
      }

      final encryptedBytes =
          await CloudService().downloadFile(targetCloudId);
      final decryptedBytes =
          await EncryptionService.decryptFile(encryptedBytes);
      await cacheFile.writeAsBytes(decryptedBytes);

      if (mounted) setState(() { _imageData = decryptedBytes; _loading = false; });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return Container(color: Colors.grey[900]);

    if (_imageData == null) {
      return Container(
        color: Colors.grey[900],
        child: Center(
          child: Icon(
            _isVideo ? Icons.play_circle_outline : Icons.broken_image,
            color: Colors.white54,
            size: 40,
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(_imageData!, fit: BoxFit.cover, cacheWidth: 200),
        if (_isVideo)
          const Center(
            child:
                Icon(Icons.play_circle_fill, color: Colors.white70, size: 40),
          ),
      ],
    );
  }
}
