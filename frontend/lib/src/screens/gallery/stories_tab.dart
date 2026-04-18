import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../config/theme.dart';
import '../../models/file_model.dart';
import '../../../services/database_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/sync_service.dart';
import 'image_viewer_screen.dart';

class StoriesTab extends StatefulWidget {
  const StoriesTab({super.key});

  @override
  State<StoriesTab> createState() => _StoriesTabState();
}

class _StoriesTabState extends State<StoriesTab> {
  List<CnestFile> _yearAgoFiles = [];
  CnestFile? _featuredVideo;
  bool _loading = true;
  bool _showFeatured = true;
  bool _showYearAgo = true;

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
    final prefs = await SharedPreferences.getInstance();
    _showFeatured = prefs.getBool('gallery_show_featured') ?? true;
    _showYearAgo = prefs.getBool('gallery_show_year_ago') ?? true;

    List<CnestFile> yearAgo = [];
    CnestFile? video;

    if (_showYearAgo) {
      yearAgo = await DatabaseService().getFilesFromOneYearAgo();
    }

    if (_showFeatured) {
      final allImages =
          await DatabaseService().getFilesByType(CnestFileType.image);
      final videos = allImages.where((f) {
        final ext = f.filename.split('.').last.toLowerCase();
        return ['mp4', 'mov', 'avi', 'mkv'].contains(ext);
      }).toList();
      if (videos.isNotEmpty) {
        video = videos[Random().nextInt(videos.length)];
      }
    }

    if (mounted) {
      setState(() {
        _yearAgoFiles = yearAgo;
        _featuredVideo = video;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final hasContent = (_showYearAgo && _yearAgoFiles.isNotEmpty) ||
        (_showFeatured && _featuredVideo != null);

    if (!hasContent) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.auto_awesome, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('No stories yet',
                style: TextStyle(color: Colors.grey, fontSize: 16)),
            SizedBox(height: 8),
            Text('Memories will appear here over time',
                style: TextStyle(color: Colors.grey, fontSize: 13)),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_showYearAgo && _yearAgoFiles.isNotEmpty) ...[
          _buildYearAgoCard(),
          const SizedBox(height: 20),
        ],
        if (_showFeatured && _featuredVideo != null) ...[
          _buildFeaturedVideoCard(),
        ],
      ],
    );
  }

  Widget _buildYearAgoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.history, color: Colors.amberAccent, size: 20),
              SizedBox(width: 8),
              Text('On this day, one year ago',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 15)),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 120,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _yearAgoFiles.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                return GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ImageViewerScreen(
                        files: _yearAgoFiles,
                        initialIndex: index,
                      ),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 120,
                      child: _ThumbnailLoader(file: _yearAgoFiles[index]),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeaturedVideoCard() {
    final video = _featuredVideo!;
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ImageViewerScreen(
            files: [video],
            initialIndex: 0,
          ),
        ),
      ),
      child: Container(
        height: 200,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _ThumbnailLoader(file: video),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black.withAlpha(180)],
                ),
              ),
            ),
            const Center(
              child:
                  Icon(Icons.play_circle_fill, color: Colors.white, size: 56),
            ),
            Positioned(
              bottom: 12,
              left: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Featured Video',
                      style: TextStyle(
                          color: Colors.amberAccent,
                          fontWeight: FontWeight.w600,
                          fontSize: 12)),
                  Text(video.filename,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThumbnailLoader extends StatefulWidget {
  final CnestFile file;
  const _ThumbnailLoader({required this.file});

  @override
  State<_ThumbnailLoader> createState() => _ThumbnailLoaderState();
}

class _ThumbnailLoaderState extends State<_ThumbnailLoader> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // LOCAL-FIRST: use device file if it exists
    if (widget.file.localPath != null) {
      final localFile = File(widget.file.localPath!);
      if (await localFile.exists()) {
        final bytes = await localFile.readAsBytes();
        if (mounted) setState(() => _bytes = bytes);
        return;
      }
    }

    // CLOUD FALLBACK
    final targetId =
        widget.file.thumbnailCloudId ?? widget.file.cloudId;
    if (targetId == null) return;

    try {
      final cacheDir = await getTemporaryDirectory();
      final isThumbnail = widget.file.thumbnailCloudId != null;
      final fileName = isThumbnail
          ? 'thumb_${widget.file.cloudId}.jpg'
          : '${widget.file.cloudId}_decrypted.jpg';
      final cacheFile = File('${cacheDir.path}/$fileName');

      if (await cacheFile.exists()) {
        final bytes = await cacheFile.readAsBytes();
        if (mounted) setState(() => _bytes = bytes);
        return;
      }

      final enc = await CloudService().downloadFile(targetId);
      final dec = await EncryptionService.decryptFile(enc);
      await cacheFile.writeAsBytes(dec);
      if (mounted) setState(() => _bytes = dec);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Image.memory(_bytes!, fit: BoxFit.cover);
    }
    return Container(color: Colors.grey[900]);
  }
}
