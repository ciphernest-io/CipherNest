import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart'; // Needed for caching
import '../../models/file_model.dart';
import '../../../services/drive_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/database_service.dart';

class ImageViewerScreen extends StatefulWidget {
  final List<CnestFile> files; // Changed from single file to List
  final int initialIndex;      // Which one did we click?

  const ImageViewerScreen({
    super.key, 
    required this.files, 
    required this.initialIndex,
  });

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  late PageController _pageController;
  late int _currentIndex;
  late List<CnestFile> _currentFiles;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _currentFiles = List.from(widget.files); // Create a mutable copy
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  Future<void> _handleDelete() async {
    final fileToDelete = _currentFiles[_currentIndex];

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete File?'),
        content: const Text('This will permanently delete the file from your Cloud Drive and Local Database.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true), 
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      // 1. Delete from Cloud
      if (fileToDelete.cloudId != null) {
        await DriveService.deleteFile(fileToDelete.cloudId!);
      }
      
      // 2. Delete from Local DB
      await DatabaseService().deleteFile(fileToDelete.id);

      // 3. Update UI
      if (mounted) {
        Navigator.pop(context, true); // <--- 'true' means "I deleted something"
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File deleted')));
      }

      if (_currentFiles.isEmpty) {
        Navigator.pop(context); // Close viewer if album is empty
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File deleted')));
      }

    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_currentFiles.isEmpty) return const SizedBox.shrink();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Column(
          children: [
            Text(
              _currentFiles[_currentIndex].filename, 
              style: const TextStyle(fontSize: 14, color: Colors.white)
            ),
            Text(
              '${_currentIndex + 1} / ${_currentFiles.length}',
              style: const TextStyle(fontSize: 10, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: _handleDelete,
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: _currentFiles.length,
        onPageChanged: (index) {
          setState(() => _currentIndex = index);
        },
        itemBuilder: (context, index) {
          return _SinglePhotoView(file: _currentFiles[index]);
        },
      ),
    );
  }
}

/// A separate widget handles loading/caching for each individual photo.
/// This makes swiping smoother because adjacent pages can pre-load.
class _SinglePhotoView extends StatefulWidget {
  final CnestFile file;

  const _SinglePhotoView({required this.file});

  @override
  State<_SinglePhotoView> createState() => _SinglePhotoViewState();
}

class _SinglePhotoViewState extends State<_SinglePhotoView> with AutomaticKeepAliveClientMixin {
  Uint8List? _imageData;
  bool _loading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true; // Keeps the photo in memory when you swipe away slightly

  @override
  void initState() {
    super.initState();
    _loadWithCache();
  }

  Future<void> _loadWithCache() async {
    try {
      if (widget.file.cloudId == null) throw Exception('File not synced');

      // 1. Check Local Cache
      final cacheDir = await getTemporaryDirectory();
      final cacheFile = File('${cacheDir.path}/${widget.file.cloudId}_decrypted.jpg');

      if (await cacheFile.exists()) {
        // HIT: Read from disk (Fast!)
        final bytes = await cacheFile.readAsBytes();
        if (mounted) setState(() { _imageData = bytes; _loading = false; });
        return;
      }

      // 2. MISS: Download & Decrypt (Slow...)
      final encryptedBytes = await DriveService.downloadFile(widget.file.cloudId!);
      final decryptedBytes = await EncryptionService.decryptFile(encryptedBytes);

      // 3. Write to Cache (for next time)
      await cacheFile.writeAsBytes(decryptedBytes);

      if (mounted) setState(() { _imageData = decryptedBytes; _loading = false; });

    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.broken_image, color: Colors.white54, size: 48),
            const SizedBox(height: 16),
            Text('Error: $_error', style: const TextStyle(color: Colors.red)),
          ],
        ),
      );
    }

    return InteractiveViewer(
      minScale: 1.0,
      maxScale: 4.0,
      child: Center(
        child: Image.memory(
          _imageData!,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}