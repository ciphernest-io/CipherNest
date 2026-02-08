import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
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
  bool _hasDeleted = false;

  static final Set<String> _activeDownloads = {};

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _currentFiles = List.from(widget.files);
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  // --- PRE-FETCHING (Keep exactly as before) ---
  Future<void> _handleCurrentPhotoLoaded(int loadedIndex) async {
    if (!mounted || loadedIndex != _currentIndex) return;
    await _downloadFileAtIndex(_currentIndex + 1);
    if (!mounted || loadedIndex != _currentIndex) return;
    await _downloadFileAtIndex(_currentIndex - 1);
    if (!mounted || loadedIndex != _currentIndex) return;
    await _downloadFileAtIndex(_currentIndex + 2);
    if (!mounted || loadedIndex != _currentIndex) return;
    await _downloadFileAtIndex(_currentIndex - 2);
  }

  Future<void> _downloadFileAtIndex(int index) async {
    if (index < 0 || index >= _currentFiles.length) return;
    final file = _currentFiles[index];
    if (file.cloudId == null) return;
    if (_activeDownloads.contains(file.cloudId)) return;

    try {
      final tempDir = await getTemporaryDirectory();
      final fullPath = '${tempDir.path}/${file.cloudId}_decrypted.jpg';
      if (File(fullPath).existsSync()) return;

      _activeDownloads.add(file.cloudId!);
      
      // Skip video pre-fetching (too large)
      final isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(file.filename.split('.').last.toLowerCase());
      if (isVideo) return; 

      final encryptedBytes = await CloudService().downloadFile(file.cloudId!);
      if (!mounted) return; 
      final decryptedBytes = await EncryptionService.decryptFile(encryptedBytes);
      await File(fullPath).writeAsBytes(decryptedBytes);
    } catch (e) {
      // Silent fail
    } finally {
      _activeDownloads.remove(file.cloudId);
    }
  }

  // --- DELETE LOGIC (Keep exactly as before) ---
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
      // 1. Delete from Cloud
      if (fileToDelete.cloudId != null) await CloudService().deleteFile(fileToDelete.cloudId!);
      if (fileToDelete.thumbnailCloudId != null) await CloudService().deleteFile(fileToDelete.thumbnailCloudId!);
      
      // 2. Delete from DB
      await DatabaseService().deleteFile(fileToDelete.id);

      // 3. AGGRESSIVE CACHE CLEANUP
      final tempDir = await getTemporaryDirectory();
      final potentialFiles = [
        // Current Naming
        File('${tempDir.path}/thumb_${fileToDelete.cloudId}.jpg'),
        File('${tempDir.path}/${fileToDelete.cloudId}_decrypted.jpg'),
        File('${tempDir.path}/${fileToDelete.id}_decrypted.mp4'),
        
        // Legacy Naming
        File('${tempDir.path}/${fileToDelete.id}_thumb.jpg'),
        File('${tempDir.path}/${fileToDelete.id}.cnest_decrypted'),
      ];

      for (final artifact in potentialFiles) {
        if (await artifact.exists()) {
          await artifact.delete();
        }
      }

      // 4. Update UI
      setState(() {
        _currentFiles.removeAt(_currentIndex);
        _hasDeleted = true;
        if (_currentFiles.isEmpty) {
          Navigator.pop(context, true);
        } else {
          if (_currentIndex >= _currentFiles.length) {
            _currentIndex = _currentFiles.length - 1;
          }
        }
      });
      
      if (_currentFiles.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File deleted')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
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
              key: ValueKey(_currentFiles[index].id), 
              file: _currentFiles[index],
              index: index, 
              onLoaded: (loadedIdx) => _handleCurrentPhotoLoaded(loadedIdx),
              isFocused: index == _currentIndex, 
            );
          },
        ),
      ),
    );
  }
}

class _SinglePhotoView extends StatefulWidget {
  final CnestFile file;
  final int index;
  final Function(int) onLoaded;
  final bool isFocused;

  const _SinglePhotoView({
    super.key, 
    required this.file,
    required this.index,
    required this.onLoaded,
    required this.isFocused,
  });

  @override
  State<_SinglePhotoView> createState() => _SinglePhotoViewState();
}

class _SinglePhotoViewState extends State<_SinglePhotoView> with AutomaticKeepAliveClientMixin {
  Uint8List? _fullImage;
  Uint8List? _thumbImage;
  bool _isLoadingFull = true;
  bool _isVideo = false;
  
  // Video Player State
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  bool _isPlayingVideo = false;
  bool _isBufferingVideo = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _checkFileType();
    _loadImages();
  }

  @override
  void didUpdateWidget(_SinglePhotoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // If we just lost focus (user swiped away), pause the video
    if (oldWidget.isFocused && !widget.isFocused) {
      _videoController?.pause();
    }
  }

  // CRITICAL: Cleanup player when swiping away to free memory
  @override
  void dispose() {
    _disposeVideoPlayer();
    super.dispose();
  }

  void _disposeVideoPlayer() {
    _chewieController?.dispose();
    _videoController?.dispose();
    _chewieController = null;
    _videoController = null;
    _isPlayingVideo = false;
  }

  void _checkFileType() {
    final ext = widget.file.filename.split('.').last.toLowerCase();
    _isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(ext);
  }

  Future<void> _downloadThumbnail(File targetFile) async {
    // If there is no separate thumbnail ID, we can't download a "small" version safely
    if (widget.file.thumbnailCloudId == null) return;

    try {
      final encryptedBytes = await CloudService().downloadFile(widget.file.thumbnailCloudId!);
      if (!mounted) return;
      
      final decryptedBytes = await EncryptionService.decryptFile(encryptedBytes);
      await targetFile.writeAsBytes(decryptedBytes);

      // Only update UI if we still don't have the full image
      // (If full image loaded first, we don't need to show the blurry thumb)
      if (mounted && _fullImage == null) {
        setState(() => _thumbImage = decryptedBytes);
      }
    } catch (e) {
      // debugPrint("Parallel thumbnail fetch failed: $e");
    }
  }

  Future<void> _loadImages() async {
    if (!mounted) return;
    final cacheDir = await getTemporaryDirectory();

    // 1. THUMBNAIL LOGIC
    final thumbFile = File('${cacheDir.path}/thumb_${widget.file.cloudId}.jpg');
    if (await thumbFile.exists()) {
      // Case A: Have it? Show it.
      if (mounted) setState(() => _thumbImage = thumbFile.readAsBytesSync());
    } else {
      // Case B: Don't have it? Download it in background!
      // This gives us the "Black -> Thumb -> Full" transition you wanted.
      _downloadThumbnail(thumbFile);
    }

    // 2. STOP HERE IF VIDEO
    // (Videos rely on the play button, which sits on top of the thumbnail we just handled)
    if (_isVideo) {
      if (mounted) {
        setState(() => _isLoadingFull = false);
        widget.onLoaded(widget.index);
      }
      return;
    }

    // 3. FULL IMAGE LOGIC
    final fullFile = File('${cacheDir.path}/${widget.file.cloudId}_decrypted.jpg');
    if (await fullFile.exists()) {
      final bytes = await fullFile.readAsBytes();
      if (mounted) {
        setState(() { _fullImage = bytes; _isLoadingFull = false; });
        widget.onLoaded(widget.index);
      }
      return;
    }

    // 4. DOWNLOAD FULL IMAGE
    if (widget.file.cloudId != null) {
      try {
        final encryptedBytes = await CloudService().downloadFile(widget.file.cloudId!);
        if (!mounted) return;
        final decryptedBytes = await EncryptionService.decryptFile(encryptedBytes);
        await fullFile.writeAsBytes(decryptedBytes);
        
        if (mounted) {
          setState(() { _fullImage = decryptedBytes; _isLoadingFull = false; });
          widget.onLoaded(widget.index);
        }
      } catch (e) {
        if (mounted) setState(() => _isLoadingFull = false);
      }
    }
  }

  // --- VIDEO PLAYER INITIALIZATION ---
  Future<void> _initializeVideo() async {
    setState(() => _isBufferingVideo = true);

    try {
      final tempDir = await getTemporaryDirectory();
      final videoFile = File('${tempDir.path}/${widget.file.id}_decrypted.mp4');

      // Check cache first
      if (!await videoFile.exists()) {
        if (widget.file.cloudId == null) throw Exception("No cloud ID");
        
        // Download & Decrypt to File Stream
        final encryptedBytes = await CloudService().downloadFile(widget.file.cloudId!);
        final decryptStream = EncryptionService.decryptToStream(encryptedBytes);
        
        final sink = videoFile.openWrite();
        await sink.addStream(decryptStream);
        await sink.close();
      }

      if (!mounted) return;

      _videoController = VideoPlayerController.file(videoFile);
      await _videoController!.initialize();

      _chewieController = ChewieController(
        videoPlayerController: _videoController!,
        autoPlay: true,
        looping: false,
        aspectRatio: _videoController!.value.aspectRatio,
        // Make it look seamless (hide full UI if you prefer, or keep it)
        showControls: true, 
        materialProgressColors: ChewieProgressColors(
          playedColor: Colors.white,
          handleColor: Colors.white,
          backgroundColor: Colors.grey,
          bufferedColor: Colors.white38,
        ),
      );

      setState(() {
        _isPlayingVideo = true;
        _isBufferingVideo = false;
      });

    } catch (e) {
      if (mounted) {
        setState(() => _isBufferingVideo = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Video Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    // VIDEO PLAYER MODE
    if (_isPlayingVideo && _chewieController != null) {
      return Center(
        child: AspectRatio(
          aspectRatio: _videoController!.value.aspectRatio,
          child: Chewie(controller: _chewieController!),
        ),
      );
    }

    // IMAGE / THUMBNAIL MODE
    return Stack(
      fit: StackFit.expand,
      children: [
        // A. Thumbnail
        if (_thumbImage != null)
          InteractiveViewer(
            minScale: 1.0,
            maxScale: 4.0,
            child: Image.memory(_thumbImage!, fit: BoxFit.contain, gaplessPlayback: true),
          ),
          
        // B. Full Image
        if (!_isVideo && _fullImage != null)
          InteractiveViewer(
            minScale: 1.0,
            maxScale: 4.0,
            child: AnimatedOpacity(
              opacity: 1.0,
              duration: const Duration(milliseconds: 200),
              child: Image.memory(_fullImage!, fit: BoxFit.contain, gaplessPlayback: true),
            ),
          ),

        // C. Video Play Button (Click to start inline player)
        if (_isVideo && !_isBufferingVideo)
          Center(
            child: GestureDetector(
              onTap: _initializeVideo,
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: const Icon(Icons.play_arrow, size: 50, color: Colors.white),
              ),
            ),
          ),

        // D. Spinner (For Image or Video Buffering)
        if ((!_isVideo && _isLoadingFull && _fullImage == null) || _isBufferingVideo)
           const Center(child: CircularProgressIndicator(color: Colors.white)),
      ],
    );
  }
}