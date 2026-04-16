import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import '../../config/theme.dart';
import '../../models/file_model.dart';
import '../../../services/database_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/auto_sync_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/sync_service.dart';
import 'image_viewer_screen.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  late Future<List<CnestFile>> _filesFuture;
  int _bottomNavIndex = 0;

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

  void _refresh() {
    setState(() {
      _filesFuture = DatabaseService().getFilesByType(CnestFileType.image);
    });
  }

  Future<void> _handleSync() async {
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true), 
            child: const Text('Delete', style: TextStyle(color: Colors.red))
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      // 1. Delete from Cloud
      if (file.cloudId != null) await CloudService().deleteFile(file.cloudId!);
      if (file.thumbnailCloudId != null) await CloudService().deleteFile(file.thumbnailCloudId!);
      
      // 2. Delete from DB and track deletion for auto-sync
      await DatabaseService().deleteFile(file.id);
      AutoSyncService.trackDeletion(file.filename, file.sizeBytes);
      DatabaseBackupService().scheduleBackup();

      // 3. AGGRESSIVE CACHE CLEANUP
      final tempDir = await getTemporaryDirectory();
      final potentialFiles = [
        // Current Naming Standards
        File('${tempDir.path}/thumb_${file.cloudId}.jpg'),       // Thumbnail
        File('${tempDir.path}/${file.cloudId}_decrypted.jpg'),   // Full Image
        File('${tempDir.path}/${file.id}_decrypted.mp4'),        // Full Video
        
        // Legacy/Fallback Naming Standards (Safety Net)
        File('${tempDir.path}/${file.id}_thumb.jpg'),
        File('${tempDir.path}/${file.id}.cnest_decrypted'),
      ];

      for (final artifact in potentialFiles) {
        if (await artifact.exists()) {
          await artifact.delete();
        }
      }

      // 4. Refresh UI
      _refresh();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Photo deleted')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Removed explicit backgroundColor: Colors.black
    return Scaffold(
      appBar: AppBar(
        title: const Text('Encrypted Gallery'),
        // Removed explicit backgroundColor/foregroundColor to use theme
        elevation: 0,
      ),
      body: FutureBuilder<List<CnestFile>>(
        future: _filesFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final files = snapshot.data!;

          return RefreshIndicator(
            onRefresh: _handleSync,
            child: files.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 300),
                      Center(child: Text('No encrypted photos yet.\nPull to sync.', textAlign: TextAlign.center)),
                    ],
                  )
                : GridView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(0),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 1.5,
                      mainAxisSpacing: 1.5,
                    ),
                    itemCount: files.length,
                    itemBuilder: (context, index) {
                      final file = files[index];
                      return GestureDetector(
                        onTap: () async {
                          final result = await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ImageViewerScreen(
                                files: files,
                                initialIndex: index,
                              ),
                            ),
                          );
                          if (result == true) _refresh(); 
                        },
                        onLongPress: () => _handleDelete(file),
                        child: _GalleryGridItem(key: ValueKey(file.id), file: file),
                      );
                    },
                  ),
          );
        },
      ),
      bottomNavigationBar: BottomNavigationBar(
        // Removed explicit backgroundColor to use theme
        selectedItemColor: AppColors.primary, 
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
        currentIndex: _bottomNavIndex,
        onTap: (index) => setState(() => _bottomNavIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.photo), label: 'Pictures'),
          BottomNavigationBarItem(icon: Icon(Icons.photo_album), label: 'Albums'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: 'Stories'),
          BottomNavigationBarItem(icon: Icon(Icons.menu), label: 'Menu'),
        ],
      ),
    );
  }
}

class _GalleryGridItem extends StatefulWidget {
  final CnestFile file;
  const _GalleryGridItem({super.key, required this.file});

  @override
  State<_GalleryGridItem> createState() => _GalleryGridItemState();
}

class _GalleryGridItemState extends State<_GalleryGridItem> {
  Uint8List? _imageData;
  bool _loading = true;
  bool _isVideo = false;

  @override
  void initState() {
    super.initState();
    _checkFileType();
    _loadThumbnail();
  }

  void _checkFileType() {
    final ext = widget.file.filename.split('.').last.toLowerCase();
    _isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(ext);
  }

  Future<void> _loadThumbnail() async {
    if (!mounted) return;
    
    // SAFETY CHECK: If it's a video and has no separate thumbnail, STOP.
    // We do NOT want to download the main file (500MB) to show a grid item.
    if (_isVideo && widget.file.thumbnailCloudId == null) {
      if (mounted) setState(() { _loading = false; });
      return;
    }

    try {
      final cacheDir = await getTemporaryDirectory();
      // If thumb exists, use it. If not, use main file (ONLY if it's an image)
      final targetCloudId = widget.file.thumbnailCloudId ?? widget.file.cloudId;
      
      if (targetCloudId == null) throw Exception("No ID");

      final isThumbnail = widget.file.thumbnailCloudId != null;
      
      // Filename logic
      final fileName = isThumbnail 
          ? 'thumb_${widget.file.cloudId}.jpg'
          : '${widget.file.cloudId}_decrypted.jpg';

      final cacheFile = File('${cacheDir.path}/$fileName');

      if (await cacheFile.exists()) {
        final bytes = await cacheFile.readAsBytes();
        if (mounted) setState(() { _imageData = bytes; _loading = false; });
        return;
      }

      final encryptedBytes = await CloudService().downloadFile(targetCloudId);
      final decryptedBytes = await EncryptionService.decryptFile(encryptedBytes);

      await cacheFile.writeAsBytes(decryptedBytes);

      if (mounted) setState(() { _imageData = decryptedBytes; _loading = false; });

    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return Container(color: Colors.grey[900]);
    
    // If no image data, show appropriate icon
    if (_imageData == null) {
      return Container(
        color: Colors.grey[900],
        child: Center(
          child: Icon(
            _isVideo ? Icons.play_circle_outline : Icons.broken_image, 
            color: Colors.white54, 
            size: 40
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(
          _imageData!,
          fit: BoxFit.cover,
          cacheWidth: 200,
        ),
        // Overlay Play Icon for Videos
        if (_isVideo)
          const Center(
            child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 40),
          ),
      ],
    );
  }
}