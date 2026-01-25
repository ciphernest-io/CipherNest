import 'dart:io'; // Fixes 'File'
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import '../../models/file_model.dart';
import '../../../services/database_service.dart';
import '../../../services/drive_service.dart';
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

  /// Syncs local database with Google Drive
  Future<void> _handleSync() async {
    try {
      // 1. Get FULL file objects
      final cloudFiles = await DriveService.listCloudFiles();

      // 2. Reconcile (Add missing, Remove ghosts)
      await DatabaseService().reconcile(cloudFiles);

      // 3. Refresh UI
      _refresh();

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Sync complete')));
      }
    } catch (e) {
      // debugPrint(e.toString());
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
                      Center(
                        child: Text(
                          'No encrypted photos yet.\nPull to sync.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),
                    ],
                  )
                : GridView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(2),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                    itemCount: files.length,
                    itemBuilder: (context, index) {
                      final file = files[index];
                      return GestureDetector(
                        onTap: () async {
                          // AWAIT the result from the viewer
                          final result = await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ImageViewerScreen(
                                files: files,
                                initialIndex: index,
                              ),
                            ),
                          );

                          // If result is true, a file was deleted. Refresh the grid.
                          if (result == true) {
                            _refresh(); // This re-queries the DB, and the deleted photo vanishes.
                          }
                        },
                        child: _GalleryGridItem(file: file),
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
  const _GalleryGridItem({required this.file});

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
      // Naming convention: thumb_{cloudId}.jpg
      // If we don't have a thumbnail ID, we try to load the main file (fallback)
      final targetCloudId = widget.file.thumbnailCloudId ?? widget.file.cloudId;
      
      if (targetCloudId == null) throw Exception("No ID");

      final isThumbnail = widget.file.thumbnailCloudId != null;
      final fileName = isThumbnail 
          ? 'thumb_${widget.file.cloudId}.jpg' // Distinct name for thumbnails
          : '${widget.file.cloudId}_decrypted.jpg'; // Main file fallback

      final cacheFile = File('${cacheDir.path}/$fileName');

      // 1. Check Cache
      if (await cacheFile.exists()) {
        final bytes = await cacheFile.readAsBytes();
        if (mounted) setState(() { _imageData = bytes; _loading = false; });
        return;
      }

      // 2. Download & Decrypt
      final encryptedBytes = await DriveService.downloadFile(targetCloudId);
      final decryptedBytes = await EncryptionService.decryptFile(encryptedBytes);

      // 3. Save to Cache
      await cacheFile.writeAsBytes(decryptedBytes);

      if (mounted) setState(() { _imageData = decryptedBytes; _loading = false; });

    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(color: Colors.grey[900]);
    }
    
    if (_imageData == null) {
      return Container(
        color: Colors.grey[900],
        child: const Icon(Icons.broken_image, color: Colors.white24),
      );
    }

    return Image.memory(
      _imageData!,
      fit: BoxFit.cover,
      cacheWidth: 200, // Memory optimization
    );
  }
}
