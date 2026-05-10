import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import '../../config/theme.dart';
import '../../models/file_model.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/database_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/auto_sync_service.dart';
import '../../../services/video_streaming_server.dart';
import '../share/share_dialog.dart';

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
  final ScrollController _filmStripController = ScrollController();
  late int _currentIndex;
  late List<CnestFile> _currentFiles;
  bool _hasDeleted = false;
  bool _showControls = true;
  static final Set<String> _activeDownloads = {};

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _currentFiles = List.from(widget.files);
    _pageController = PageController(
      initialPage: widget.initialIndex,
      viewportFraction: 1.05,
    );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToIndex(_currentIndex),
    );
  }

  void _scrollToIndex(int index) {
    if (!_filmStripController.hasClients) return;
    // itemWidth (40) + margin (8) = 48 pixels per item
    const itemSize = 48.0;
    final screenWidth = MediaQuery.of(context).size.width;
    // Center the item: (Index * Size) - (Half Screen) + (Half Item)
    final offset = (index * itemSize) - (screenWidth / 2) + (itemSize / 2);

    _filmStripController.animateTo(
      offset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
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

    // LOCAL-FIRST: skip download if the original exists on device
    if (file.localPath != null && File(file.localPath!).existsSync()) return;

    if (_activeDownloads.contains(file.cloudId)) return;

    try {
      final tempDir = await getTemporaryDirectory();
      final fullPath = '${tempDir.path}/${file.cloudId}_decrypted.jpg';
      if (File(fullPath).existsSync()) return;

      _activeDownloads.add(file.cloudId!);

      // Skip video pre-fetching (too large)
      final isVideo = [
        'mp4',
        'mov',
        'avi',
        'mkv',
      ].contains(file.filename.split('.').last.toLowerCase());
      if (isVideo) return;

      final encryptedBytes = await CloudService().downloadFile(file.cloudId!);
      if (!mounted) return;
      final decryptedBytes = await EncryptionService.decryptFile(
        encryptedBytes,
      );
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
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
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
      if (fileToDelete.cloudId != null)
        await CloudService().deleteFile(fileToDelete.cloudId!);
      if (fileToDelete.thumbnailCloudId != null)
        await CloudService().deleteFile(fileToDelete.thumbnailCloudId!);

      // 2. Delete from DB and track deletion for auto-sync
      await DatabaseService().deleteFile(fileToDelete.id);
      AutoSyncService.trackDeletion(fileToDelete.filename, fileToDelete.sizeBytes);
      DatabaseBackupService().scheduleBackup();

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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('File deleted')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  void _showDetailsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.4,
        minChildSize: 0.2,
        maxChildSize: 0.6,
        expand: false,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(24),
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text("Details", style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 20),
            _DetailItem(
              icon: PhosphorIcons.file(PhosphorIconsStyle.thin),
              title: "Filename",
              value: _currentFiles[_currentIndex].filename,
            ),
            _DetailItem(
              icon: PhosphorIcons.calendar(PhosphorIconsStyle.thin),
              title: "Created",
              value: _currentFiles[_currentIndex].createdAt.toString().split(
                '.',
              )[0],
            ),
            _DetailItem(
              icon: PhosphorIcons.fingerprint(PhosphorIconsStyle.thin),
              title: "ID",
              value: _currentFiles[_currentIndex].id,
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _onWillPop() async {
    Navigator.pop(context, _hasDeleted);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_currentFiles.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    const overlayColor = Colors.white;

    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: _showControls
            ? AppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                iconTheme: const IconThemeData(color: overlayColor),
                title: Column(
                  children: [
                    Text(
                      _currentFiles[_currentIndex].filename,
                      style: const TextStyle(fontSize: 14, color: overlayColor),
                    ),
                    Text(
                      '${_currentIndex + 1} / ${_currentFiles.length}',
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
                leading: IconButton(
                  icon: Icon(PhosphorIcons.arrowLeft(PhosphorIconsStyle.thin)),
                  onPressed: () => Navigator.pop(context, _hasDeleted),
                ),
                actions: [
                  IconButton(
                    icon: Icon(PhosphorIcons.arrowsCounterClockwise(PhosphorIconsStyle.thin)),
                    onPressed: () {},
                  ),
                  PopupMenuButton<String>(
                    icon: Icon(PhosphorIcons.dotsThreeVertical(PhosphorIconsStyle.thin), color: overlayColor),
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'copy',
                        child: Text('Copy to clipboard'),
                      ),
                      const PopupMenuItem(
                        value: 'wall',
                        child: Text('Set as wallpaper'),
                      ),
                      const PopupMenuItem(value: 'print', child: Text('Print')),
                    ],
                    onSelected: (val) {},
                  ),
                ],
              )
            : null,

        body: Stack(
          children: [
            // --- FIX: SWIPE UP GESTURE (Using Listener instead of GestureDetector) ---
            Listener(
              onPointerMove: (event) {
                // Raw detection: if we move UP significantly, trigger sheet
                if (event.delta.dy < -10) {
                  _showDetailsSheet();
                }
              },
              child: GestureDetector(
                onTap: () => setState(() => _showControls = !_showControls),
                child: Dismissible(
                  key: const Key('viewer_dismiss'),
                  direction:
                      DismissDirection.down, // Only swipe down to dismiss
                  onDismissed: (direction) =>
                      Navigator.pop(context, _hasDeleted),
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: _currentFiles.length,
                    onPageChanged: (index) {
                      setState(() => _currentIndex = index);
                      // FIX: Sync filmstrip when swiping main photo
                      _scrollToIndex(index);
                    },
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2.5),
                        child: _SinglePhotoView(
                          key: ValueKey(_currentFiles[index].id),
                          file: _currentFiles[index],
                          index: index,
                          onLoaded: (loadedIdx) =>
                              _handleCurrentPhotoLoaded(loadedIdx),
                          isFocused: index == _currentIndex,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),

            // --- BOTTOM CONTROLS ---
            if (_showControls)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: theme.colorScheme.surface.withOpacity(0.9),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // --- FIX: DRAGGABLE SLIDER (Filmstrip) ---
                        GestureDetector(
                          // Handle scrubbing (dragging finger across strip)
                          onHorizontalDragUpdate: (details) {
                            final box =
                                context.findRenderObject() as RenderBox?;
                            if (box == null) return;

                            // 48.0 is approx width of item + margin
                            const itemWidth = 48.0;

                            // Map local position to an index
                            // This is a rough estimation for "Scrubbing" feeling
                            final localDx = details.localPosition.dx;

                            // Calculate which index we are "touching" relative to the scroll view
                            // This is simplified logic: just jump next/prev based on speed for now
                            // OR simply allow the user to scroll the list manually.

                            // BETTER: Just let the user scroll the list normally (ListView handles drag)
                            // and Tap to select.
                            // Samsung style "rapid scrub" requires a Slider widget logic which is complex.
                            // For now, let's stick to the ListView scrolling naturally.
                          },
                          child: SizedBox(
                            height: 56,
                            child: ListView.builder(
                              controller:
                                  _filmStripController, // Attach controller
                              scrollDirection: Axis.horizontal,
                              itemCount: _currentFiles.length,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                              itemBuilder: (context, index) {
                                final isSelected = index == _currentIndex;
                                return GestureDetector(
                                  onTap: () {
                                    _pageController.jumpToPage(index);
                                    // No need to call _scrollToIndex here, onPageChanged handles it
                                  },
                                  child: Container(
                                    width: 40,
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      border: isSelected
                                          ? Border.all(
                                              color: AppColors.primary,
                                              width: 2,
                                            )
                                          : null,
                                    ),
                                    child: _FilmstripItem(
                                      key: ValueKey(
                                        _currentFiles[index].id,
                                      ), // <--- ADD THIS LINE
                                      file: _currentFiles[index],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),

                        // 2. ACTION BUTTONS
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              IconButton(
                                icon: Icon(PhosphorIcons.heart(PhosphorIconsStyle.thin)),
                                onPressed: () {},
                                color: overlayColor,
                              ),
                              IconButton(
                                icon: Icon(PhosphorIcons.pencilSimple(PhosphorIconsStyle.thin)),
                                onPressed: () {},
                                color: overlayColor,
                              ),
                              IconButton(
                                icon: Icon(PhosphorIcons.info(PhosphorIconsStyle.thin)),
                                onPressed: _showDetailsSheet,
                                color: overlayColor,
                              ),
                              IconButton(
                                icon: Icon(PhosphorIcons.shareFat(PhosphorIconsStyle.thin)),
                                onPressed: () => ShareDialog.show(
                                    context, _currentFiles[_currentIndex]),
                                color: overlayColor,
                              ),
                              IconButton(
                                icon: Icon(PhosphorIcons.trash(PhosphorIconsStyle.thin)),
                                onPressed: _handleDelete,
                                color: Colors.redAccent,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DetailItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  const _DetailItem({
    required this.icon,
    required this.title,
    required this.value,
  });
  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Theme.of(context).iconTheme.color),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text(value),
      contentPadding: EdgeInsets.zero,
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

class _SinglePhotoViewState extends State<_SinglePhotoView>
    with AutomaticKeepAliveClientMixin {
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
    // Drop cached file key + session metadata
    VideoStreamingServer().endSession(widget.file.id);
  }

  void _checkFileType() {
    final ext = widget.file.filename.split('.').last.toLowerCase();
    _isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(ext);
  }

  Future<void> _downloadThumbnail(File targetFile) async {
    // If there is no separate thumbnail ID, we can't download a "small" version safely
    if (widget.file.thumbnailCloudId == null) return;

    try {
      final encryptedBytes = await CloudService().downloadFile(
        widget.file.thumbnailCloudId!,
      );
      if (!mounted) return;

      final decryptedBytes = await EncryptionService.decryptFile(
        encryptedBytes,
      );
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

    // LOCAL-FIRST: If the original file exists on device, use it directly
    if (widget.file.localPath != null) {
      final localFile = File(widget.file.localPath!);
      if (await localFile.exists()) {
        if (_isVideo) {
          // For videos, show thumbnail from local path, video player handles playback
          if (mounted) {
            setState(() => _isLoadingFull = false);
            widget.onLoaded(widget.index);
          }
          return;
        }
        final bytes = await localFile.readAsBytes();
        if (mounted) {
          setState(() {
            _fullImage = bytes;
            _isLoadingFull = false;
          });
          widget.onLoaded(widget.index);
        }
        return;
      }
    }

    // CLOUD FALLBACK: existing download+decrypt flow
    final cacheDir = await getTemporaryDirectory();

    // 1. THUMBNAIL LOGIC
    final thumbFile = File('${cacheDir.path}/thumb_${widget.file.cloudId}.jpg');
    if (await thumbFile.exists()) {
      if (mounted) setState(() => _thumbImage = thumbFile.readAsBytesSync());
    } else {
      _downloadThumbnail(thumbFile);
    }

    // 2. STOP HERE IF VIDEO
    if (_isVideo) {
      if (mounted) {
        setState(() => _isLoadingFull = false);
        widget.onLoaded(widget.index);
      }
      return;
    }

    // 3. FULL IMAGE LOGIC
    final fullFile = File(
      '${cacheDir.path}/${widget.file.cloudId}_decrypted.jpg',
    );
    if (await fullFile.exists()) {
      final bytes = await fullFile.readAsBytes();
      if (mounted) {
        setState(() {
          _fullImage = bytes;
          _isLoadingFull = false;
        });
        widget.onLoaded(widget.index);
      }
      return;
    }

    // 4. DOWNLOAD FULL IMAGE
    if (widget.file.cloudId != null) {
      try {
        final encryptedBytes = await CloudService().downloadFile(
          widget.file.cloudId!,
        );
        if (!mounted) return;
        final decryptedBytes = await EncryptionService.decryptFile(
          encryptedBytes,
        );
        await fullFile.writeAsBytes(decryptedBytes);

        if (mounted) {
          setState(() {
            _fullImage = decryptedBytes;
            _isLoadingFull = false;
          });
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
      // LOCAL-FIRST: if the original is on device, play it directly.
      // Zero network, zero decryption.
      if (widget.file.localPath != null) {
        final localFile = File(widget.file.localPath!);
        if (await localFile.exists()) {
          _videoController = VideoPlayerController.file(localFile);
          await _videoController!.initialize();
          _setupChewie();
          return;
        }
      }

      // CLOUD STREAMING: spin up local proxy server, point player at it.
      // Player issues HTTP range requests; server fetches encrypted chunks
      // on demand, decrypts only what's needed, returns plaintext slices.
      if (widget.file.cloudId == null) throw Exception('No cloud ID');

      final url = await VideoStreamingServer().beginSession(widget.file);
      if (!mounted) return;

      _videoController = VideoPlayerController.networkUrl(Uri.parse(url));
      await _videoController!.initialize();
      _setupChewie();
    } catch (e) {
      if (mounted) {
        setState(() => _isBufferingVideo = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Video Error: $e')));
      }
    }
  }

  void _setupChewie() {
    if (!mounted || _videoController == null) return;
    _chewieController = ChewieController(
      videoPlayerController: _videoController!,
      autoPlay: true,
      looping: false,
      aspectRatio: _videoController!.value.aspectRatio,
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
            child: Image.memory(
              _thumbImage!,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),

        // B. Full Image
        if (!_isVideo && _fullImage != null)
          InteractiveViewer(
            minScale: 1.0,
            maxScale: 4.0,
            child: AnimatedOpacity(
              opacity: 1.0,
              duration: const Duration(milliseconds: 200),
              child: Image.memory(
                _fullImage!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
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
                child: Icon(
                  PhosphorIcons.play(PhosphorIconsStyle.fill),
                  size: 50,
                  color: Colors.white,
                ),
              ),
            ),
          ),

        // D. Spinner (For Image or Video Buffering)
        if ((!_isVideo && _isLoadingFull && _fullImage == null) ||
            _isBufferingVideo)
          const Center(child: CircularProgressIndicator(color: Colors.white)),
      ],
    );
  }
}

// Minimal widget for the filmstrip items
class _FilmstripItem extends StatefulWidget {
  final CnestFile file;
  const _FilmstripItem({super.key, required this.file});
  @override
  State<_FilmstripItem> createState() => _FilmstripItemState();
}

class _FilmstripItemState extends State<_FilmstripItem> {
  Uint8List? _data;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cacheDir = await getTemporaryDirectory();
    final f = File('${cacheDir.path}/thumb_${widget.file.cloudId}.jpg');
    if (await f.exists()) {
      if (mounted) setState(() => _data = f.readAsBytesSync());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_data == null) return Container(color: Colors.grey[800]);
    return Image.memory(_data!, fit: BoxFit.cover);
  }
}
