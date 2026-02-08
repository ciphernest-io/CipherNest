import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import '../../models/file_model.dart';
import '../../../services/database_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/encryption_service.dart';
import 'image_viewer_screen.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  late Future<List<CnestFile>> _filesFuture;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _filesFuture = DatabaseService().getFilesByType(CnestFileType.image);
    });
  }

  /// Syncs local database with Cloud
  Future<void> _handleSync() async {
    try {
      final cloudFiles = await CloudService().listCloudFiles();
      await DatabaseService().reconcile(cloudFiles);
      _refresh();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sync complete')));
      }
    } catch (e) {
      // debugPrint(e.toString());
    }
  }

  // Handle delete directly from Grid (Long Press)
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
      // 1. Delete from Cloud & DB
      if (file.cloudId != null) await CloudService().deleteFile(file.cloudId!);
      if (file.thumbnailCloudId != null) await CloudService().deleteFile(file.thumbnailCloudId!);
      await DatabaseService().deleteFile(file.id);

      // 2. Clean Local Cache
      final tempDir = await getTemporaryDirectory();
      final thumb = File('${tempDir.path}/${file.id}_thumb.jpg');
      final main = File('${tempDir.path}/${file.id}.cnest_decrypted');
      if (thumb.existsSync()) thumb.deleteSync();
      if (main.existsSync()) main.deleteSync();

      // 3. Update UI
      _refresh();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Photo deleted')));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Encrypted Gallery')),
      body: FutureBuilder<List<CnestFile>>(
        future: _filesFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final files = snapshot.data!;

          return RefreshIndicator(
            onRefresh: _handleSync,
            child: files.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 300),
                      Center(child: Text('No encrypted photos yet.\nPull to sync.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54))),
                    ],
                  )
                : GridView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(2),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
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

                          // If result is true, a file was deleted. Refresh.
                          if (result == true) {
                            _refresh(); 
                          }
                        },
                        onLongPress: () => _handleDelete(file),
                        child: _GalleryGridItem(
                          // FIX: Key ensures widget rebuilds when data shifts
                          key: ValueKey(file.id), 
                          file: file
                        ),
                      );
                    },
                  ),
          );
        },
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

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    if (!mounted) return;
    
    try {
      final cacheDir = await getTemporaryDirectory();
      final targetCloudId = widget.file.thumbnailCloudId ?? widget.file.cloudId;
      
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
    if (_imageData == null) return Container(color: Colors.grey[900], child: const Icon(Icons.broken_image, color: Colors.white24));

    return Image.memory(
      _imageData!,
      fit: BoxFit.cover,
      cacheWidth: 200,
    );
  }
}