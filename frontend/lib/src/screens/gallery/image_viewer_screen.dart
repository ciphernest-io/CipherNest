import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../models/file_model.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/database_service.dart';

class ImageViewerScreen extends StatefulWidget {
  final List<CnestFile> files;
  final int initialIndex;

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
  bool _hasDeleted = false; // Tracks if we need to refresh gallery on return

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _currentFiles = List.from(widget.files);
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  Future<void> _handleDelete() async {
    final fileToDelete = _currentFiles[_currentIndex];

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete File?'),
        content: const Text('This will permanently delete the file.'),
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
      // 1. Delete Logic
      if (fileToDelete.cloudId != null) await CloudService().deleteFile(fileToDelete.cloudId!);
      if (fileToDelete.thumbnailCloudId != null) await CloudService().deleteFile(fileToDelete.thumbnailCloudId!);
      await DatabaseService().deleteFile(fileToDelete.id);

      // 2. Clear Cache
      final tempDir = await getTemporaryDirectory();
      final thumb = File('${tempDir.path}/${fileToDelete.id}_thumb.jpg');
      final main = File('${tempDir.path}/${fileToDelete.id}.cnest_decrypted');
      if (thumb.existsSync()) thumb.deleteSync();
      if (main.existsSync()) main.deleteSync();

      // 3. UI Update (Shift to next photo)
      setState(() {
        _currentFiles.removeAt(_currentIndex);
        _hasDeleted = true;

        if (_currentFiles.isEmpty) {
          Navigator.pop(context, true); // Empty album, go back
        } else {
          // Adjust index if we were at the end
          if (_currentIndex >= _currentFiles.length) {
            _currentIndex = _currentFiles.length - 1;
          }
        }
      });

      if (_currentFiles.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File deleted')));
      }

    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  Future<bool> _onWillPop() async {
    Navigator.pop(context, _hasDeleted);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_currentFiles.isEmpty) return const SizedBox.shrink();

    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
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
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, _hasDeleted),
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
            return _SinglePhotoView(
              // FIX: Key is CRITICAL here. It forces a rebuild when the file at this index changes.
              key: ValueKey(_currentFiles[index].id), 
              file: _currentFiles[index]
            );
          },
        ),
      ),
    );
  }
}

class _SinglePhotoView extends StatefulWidget {
  final CnestFile file;
  const _SinglePhotoView({super.key, required this.file});

  @override
  State<_SinglePhotoView> createState() => _SinglePhotoViewState();
}

class _SinglePhotoViewState extends State<_SinglePhotoView> with AutomaticKeepAliveClientMixin {
  Uint8List? _fullImage;
  Uint8List? _thumbImage;
  bool _isLoadingFull = true;
  
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  Future<void> _loadImages() async {
    if (!mounted) return;
    final cacheDir = await getTemporaryDirectory();

    // 1. Load Thumbnail
    final thumbFile = File('${cacheDir.path}/thumb_${widget.file.cloudId}.jpg');
    if (await thumbFile.exists()) {
      if (mounted) setState(() => _thumbImage = thumbFile.readAsBytesSync());
    }

    // 2. Check for Full Image
    final fullFile = File('${cacheDir.path}/${widget.file.cloudId}_decrypted.jpg');
    if (await fullFile.exists()) {
      final bytes = await fullFile.readAsBytes();
      if (mounted) setState(() { _fullImage = bytes; _isLoadingFull = false; });
      return;
    }

    // 3. Download Full
    if (widget.file.cloudId != null) {
      try {
        final encryptedBytes = await CloudService().downloadFile(widget.file.cloudId!);
        final decryptedBytes = await EncryptionService.decryptFile(encryptedBytes);
        await fullFile.writeAsBytes(decryptedBytes);
        
        if (mounted) setState(() { _fullImage = decryptedBytes; _isLoadingFull = false; });
      } catch (e) {
        if (mounted) setState(() => _isLoadingFull = false);
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
        fit: StackFit.expand,
        children: [
          if (_thumbImage != null)
            Image.memory(_thumbImage!, fit: BoxFit.contain, gaplessPlayback: true),
            
          if (_fullImage != null)
            AnimatedOpacity(
              opacity: 1.0,
              duration: const Duration(milliseconds: 200),
              child: Image.memory(_fullImage!, fit: BoxFit.contain, gaplessPlayback: true),
            ),

          if (_isLoadingFull && _fullImage == null)
             const Center(child: CircularProgressIndicator(color: Colors.white)),
        ],
      ),
    );
  }
}