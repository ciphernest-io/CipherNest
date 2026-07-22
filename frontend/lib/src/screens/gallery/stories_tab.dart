import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/file_model.dart';
import '../../../services/cache_manager_service.dart';
import '../../../services/database_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/gallery_prefs.dart';
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
    DatabaseService().addListener(_reload);
    // Settings toggles for "show featured" / "show a year ago" write through
    // GalleryPrefs; without this listener the toggle takes effect only on
    // the next sync or DB mutation.
    GalleryPrefs().changed.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    SyncService().syncNotifier.removeListener(_reload);
    DatabaseService().removeListener(_reload);
    GalleryPrefs().changed.removeListener(_reload);
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

    final cs = Theme.of(context).colorScheme;

    if (!hasContent) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ThemeIcon('sparkle', size: 64, color: cs.onSurface.withAlpha(120)),
            const SizedBox(height: 16),
            Text('No stories yet',
                style: TextStyle(color: cs.onSurface.withAlpha(120), fontSize: 16)),
            const SizedBox(height: 8),
            Text('Memories will appear here over time',
                style: TextStyle(color: cs.onSurface.withAlpha(120), fontSize: 13)),
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
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(t.rCard),
        border: Border.all(color: cs.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ThemeIcon('clockCounterClockwise', color: cs.primary, size: 20),
              const SizedBox(width: 8),
              Text('On this day, one year ago',
                  style: TextStyle(
                      color: cs.onSurface,
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
                    borderRadius: BorderRadius.circular(t.rInput),
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
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
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
          color: cs.surface,
          borderRadius: BorderRadius.circular(t.rCardLg),
          border: Border.all(color: cs.outline),
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
                  colors: [Colors.transparent, t.scrim],
                ),
              ),
            ),
            Center(
              child:
                  ThemeIcon('playCircle', selected: true, color: Colors.white, size: 56),
            ),
            Positioned(
              bottom: 12,
              left: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Featured Video',
                      style: TextStyle(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                          fontSize: 12)),
                  Text(video.filename,
                      style:
                          TextStyle(color: cs.onSurface.withAlpha(180), fontSize: 13),
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

  bool get _isVideo {
    final ext = widget.file.filename.split('.').last.toLowerCase();
    return const {'mp4', 'mov', 'avi', 'mkv'}.contains(ext);
  }

  /// Fire-and-forget: share the obtained frame through the standard
  /// thumb-cache path so the grid, filmstrip, and viewer reuse it.
  /// MediaStore-bound files are excluded (same assetId == null gate as the
  /// viewer/filmstrip persist helpers): Android re-serves their frame on
  /// demand, and this ungated write — running for every video story card
  /// the moment the gallery's IndexedStack builds this tab — was why the
  /// app-cache figure jumped on entering the gallery even though the grid
  /// itself writes nothing.
  void _persistFrame(Uint8List bytes) {
    if (widget.file.assetId != null) return;
    final cloudId = widget.file.cloudId;
    if (cloudId == null) return;
    getTemporaryDirectory().then((dir) async {
      try {
        await File('${dir.path}/thumb_$cloudId.jpg').writeAsBytes(bytes);
      } catch (_) {
        // Best-effort cache write.
      }
    });
  }

  Future<void> _load() async {
    // Videos first: their raw bytes are not decodable as an image, so they
    // need a real frame — same rungs as the gallery grid and filmstrip.
    if (_isVideo) {
      // Rung 0 — the shared disk thumb cache. MediaStore-bound files skip
      // it: Android serves their frame, and a disk thumb here can only be a
      // stale leftover from a window when the local original was missing
      // (gallery delete → restore). Serving it first kept the leftover
      // alive forever.
      if (widget.file.assetId == null && widget.file.cloudId != null) {
        final dir = await getTemporaryDirectory();
        final cached = File('${dir.path}/thumb_${widget.file.cloudId}.jpg');
        if (await cached.exists()) {
          final bytes = await cached.readAsBytes();
          if (mounted) setState(() => _bytes = bytes);
          return;
        }
      }
      // Rung 1 — MediaStore.
      if (widget.file.assetId != null) {
        try {
          final asset = await AssetEntity.fromId(widget.file.assetId!);
          final bytes = await asset?.thumbnailDataWithSize(
            const ThumbnailSize(600, 600),
          );
          if (bytes != null) {
            _persistFrame(bytes);
            // MediaStore verified as the source — reclaim any leftover
            // decrypted copies. Stories re-runs _load on every rebuild
            // (no memo), so this converges even when the grid tile's
            // session memo skips its own ladder.
            unawaited(CacheManagerService().reclaimForMediaStoreOriginal(
              fileId: widget.file.id,
              cloudId: widget.file.cloudId,
            ));
            if (mounted) setState(() => _bytes = bytes);
            return;
          }
        } catch (_) {
          // fall through
        }
      }
      // Rung 2 — extract a frame from the local original.
      if (widget.file.localPath != null &&
          File(widget.file.localPath!).existsSync()) {
        try {
          final bytes = await VideoThumbnail.thumbnailData(
            video: widget.file.localPath!,
            imageFormat: ImageFormat.JPEG,
            maxWidth: 600,
            quality: 70,
          );
          if (bytes != null) {
            _persistFrame(bytes);
            if (mounted) setState(() => _bytes = bytes);
            return;
          }
        } catch (_) {
          // fall through to the cloud thumb
        }
      }
      // Rung 3 — the encrypted cloud thumbnail only. Never fall back to the
      // full video blob: it isn't an image, and it can be hundreds of MB.
      if (widget.file.thumbnailCloudId == null) return;
    }

    // LOCAL-FIRST: use device file if it exists (images only — a video
    // never reaches here with a local original).
    if (!_isVideo && widget.file.localPath != null) {
      final localFile = File(widget.file.localPath!);
      if (await localFile.exists()) {
        final bytes = await localFile.readAsBytes();
        if (mounted) setState(() => _bytes = bytes);
        return;
      }
    }

    // CLOUD FALLBACK
    final targetId = _isVideo
        ? widget.file.thumbnailCloudId
        : (widget.file.thumbnailCloudId ?? widget.file.cloudId);
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
    return Container(color: Theme.of(context).colorScheme.surfaceContainerHighest);
  }
}
