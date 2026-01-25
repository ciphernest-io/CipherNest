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
      if (fileToDelete.thumbnailCloudId != null) {
        await DriveService.deleteFile(fileToDelete.thumbnailCloudId!);
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
          _precacheNeighbor(index + 1);
          _precacheNeighbor(index - 1);
        },
        itemBuilder: (context, index) {
          return _SinglePhotoView(file: _currentFiles[index]);
        },
      ),
    );
  }

  void _precacheNeighbor(int index) {
    if (index < 0 || index >= widget.files.length) return;
    // We just access the file logic. The _SinglePhotoView state handles logic, 
    // but since PageView lazy-loads, we can't easily force it to build widgets that are off-screen.
    // A simple hack for V1: The PageView actually renders the next/prev page if we keep viewport fraction default.
    // Flutter's cacheExtent usually handles this.
    // If it's still black, we might need to manually trigger a download service here.
    // For now, let's trust the updated _SinglePhotoView logic first.
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
  Uint8List? _fullImage;
  Uint8List? _thumbImage;
  bool _isLoadingFull = true;
  
  @override
  bool get wantKeepAlive => true; // Essential for swipe smoothness

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  Future<void> _loadImages() async {
    if (!mounted) return;
    final cacheDir = await getTemporaryDirectory();

    // 1. Load Thumbnail IMMEDIATELY (if exists)
    // This removes the "black screen" on initial load
    final thumbFile = File('${cacheDir.path}/thumb_${widget.file.cloudId}.jpg');
    if (await thumbFile.exists()) {
      if (mounted) {
        setState(() {
          _thumbImage = thumbFile.readAsBytesSync();
        });
      }
    }

    // 2. Check for Full Image
    final fullFile = File('${cacheDir.path}/${widget.file.cloudId}_decrypted.jpg');
    if (await fullFile.exists()) {
      final bytes = await fullFile.readAsBytes();
      if (mounted) setState(() { _fullImage = bytes; _isLoadingFull = false; });
      return;
    }

    // 3. If no full image, fetch it
    if (widget.file.cloudId != null) {
      try {
        final encryptedBytes = await DriveService.downloadFile(widget.file.cloudId!);
        final decryptedBytes = await EncryptionService.decryptFile(encryptedBytes);
        await fullFile.writeAsBytes(decryptedBytes);
        
        if (mounted) {
          setState(() { 
            _fullImage = decryptedBytes; 
            _isLoadingFull = false; 
          });
        }
      } catch (e) {
        debugPrint("Error loading full image: $e");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return InteractiveViewer(
      minScale: 1.0,
      maxScale: 4.0,
      child: Stack(
        fit: StackFit.expand, // Fill the screen
        children: [
          // Layer 1: Thumbnail (Always visible until obscured)
          if (_thumbImage != null)
            Image.memory(
              _thumbImage!,
              fit: BoxFit.contain,
              gaplessPlayback: true, // Prevents flickering
            ),
            
          // Layer 2: Full Image (Fade In)
          if (_fullImage != null)
            AnimatedOpacity(
              opacity: _fullImage != null ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: Image.memory(
                _fullImage!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
            ),

          // Layer 3: Spinner (Only if we have NOTHING)
          if (_isLoadingFull && _fullImage == null)
             const Center(child: CircularProgressIndicator(color: Colors.white)),
        ],
      ),
    );
  }
}