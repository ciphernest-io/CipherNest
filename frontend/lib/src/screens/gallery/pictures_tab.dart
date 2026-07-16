import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/file_model.dart';
import '../../utils/date_grouper.dart';
import '../../../services/cache_manager_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/local_content_guard.dart';
import '../../../services/database_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/auto_sync_service.dart';
import '../../../services/sync_service.dart';
import '../share/share_dialog.dart';
import 'image_viewer_screen.dart';

class PicturesTab extends StatefulWidget {
  const PicturesTab({super.key});

  @override
  State<PicturesTab> createState() => PicturesTabState();
}

class PicturesTabState extends State<PicturesTab> {
  static const String _columnCountPrefKey = 'gallery_column_count';
  static const int _minColumns = 2;
  static const int _maxColumns = 5;

  late Future<List<CnestFile>> _filesFuture;
  bool _favoritesOnly = false;
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  int _columnCount = 3;
  // Accumulator for scale gestures — reset on each step so a single pinch
  // can only step the grid by one column at a time.
  double _pendingScale = 1.0;

  @override
  void initState() {
    super.initState();
    SyncService().syncNotifier.addListener(_onSyncComplete);
    // DatabaseService fires notifyListeners on delete/restore/addFile so the
    // grid rebuilds without a pull-to-refresh after any mutation, including
    // ones initiated from other screens (album detail, image viewer).
    DatabaseService().addListener(_onDatabaseChanged);
    _refresh();
    _loadColumnCount();
  }

  Future<void> _loadColumnCount() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_columnCountPrefKey) ?? 3;
    if (!mounted) return;
    setState(() {
      _columnCount = saved.clamp(_minColumns, _maxColumns);
    });
  }

  Future<void> _persistColumnCount() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_columnCountPrefKey, _columnCount);
  }

  void _onScaleStart(ScaleStartDetails _) {
    _pendingScale = 1.0;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // Ignore pure pans — only react to actual pinch deltas so vertical
    // scrolling stays smooth.
    if (details.pointerCount < 2) return;
    _pendingScale = details.scale;
    if (_pendingScale > 1.4 && _columnCount > _minColumns) {
      setState(() => _columnCount -= 1);
      _pendingScale = 1.0;
      return;
    }
    if (_pendingScale < 0.7 && _columnCount < _maxColumns) {
      setState(() => _columnCount += 1);
      _pendingScale = 1.0;
    }
  }

  void _onScaleEnd(ScaleEndDetails _) {
    _persistColumnCount();
  }

  @override
  void dispose() {
    SyncService().syncNotifier.removeListener(_onSyncComplete);
    DatabaseService().removeListener(_onDatabaseChanged);
    super.dispose();
  }

  void _onSyncComplete() {
    if (mounted) _refresh();
  }

  void _onDatabaseChanged() {
    if (mounted) _refresh();
  }

  void refresh() => _refresh();

  void _refresh() {
    setState(() {
      _filesFuture = _loadFiles();
    });
  }

  Future<List<CnestFile>> _loadFiles() async {
    final images =
        await DatabaseService().getFilesByType(CnestFileType.image);
    if (_favoritesOnly) {
      return images.where((f) => f.isFavorite).toList();
    }
    return images;
  }

  void _enterSelection(String id) {
    setState(() {
      _selectionMode = true;
      _selectedIds.add(id);
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
      if (_selectedIds.isEmpty) _selectionMode = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  Future<void> _deleteSelected(List<CnestFile> all) async {
    final picked = all.where((f) => _selectedIds.contains(f.id)).toList();
    if (picked.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Move ${picked.length} photos to Recycle Bin?'),
        content: const Text(
          'They will be hidden from your gallery and permanently deleted '
          'after 30 days. Restore from Settings > Recycle Bin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Delete',
              style: TextStyle(color: ThemeController().tokens.danger),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    // Soft-delete only — encrypted blobs stay in cloud until the sweep runs
    // so users can restore offline.
    for (final f in picked) {
      try {
        await DatabaseService().deleteFile(f.id);
        AutoSyncService.trackDeletion(f.filename, f.sizeBytes);
      } catch (_) {
        // Silent — best-effort bulk delete.
      }
    }
    DatabaseBackupService().scheduleBackup();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${picked.length} photo${picked.length == 1 ? '' : 's'} '
            'moved to Recycle Bin',
          ),
        ),
      );
    }
    _exitSelection();
    _refresh();
  }

  Future<void> _shareSelectedFilenames(List<CnestFile> all) async {
    // Bulk share of encrypted files isn't a single share — surface a sheet
    // explaining and offering "share first" for the highest-selected one,
    // since the magic link format is per-file.
    final picked = all.where((f) => _selectedIds.contains(f.id)).toList();
    if (picked.isEmpty) return;
    if (picked.length == 1) {
      await ShareDialog.show(context, picked.first);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Multi-file share isn\'t available yet — share photos one at a time.',
          ),
        ),
      );
    }
  }

  Future<void> handleSync() async {
    await SyncService().syncNow(force: true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sync complete')),
      );
    }
  }


  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return FutureBuilder<List<CnestFile>>(
      future: _filesFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final files = snapshot.data!;

        if (files.isEmpty) {
          return RefreshIndicator(
            onRefresh: handleSync,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 300),
                Center(
                    child: Text('No encrypted photos yet.\nPull to sync.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withAlpha(120)))),
              ],
            ),
          );
        }

        final sections = groupByDate(files);

        // Build a flat list for ImageViewerScreen navigation
        final flatFiles = files;

        // Landscape gets ~1.5x the persisted column count so the grid stays
        // dense across the wider canvas. Clamped to 8 to avoid postage-stamp
        // thumbnails on tablets.
        final orientation = MediaQuery.of(context).orientation;
        final effectiveColumnCount = orientation == Orientation.landscape
            ? (_columnCount * 1.5).round().clamp(2, 8)
            : _columnCount;

        return RefreshIndicator(
          onRefresh: handleSync,
          child: Column(
            children: [
              _buildToolbar(files),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onScaleStart: _onScaleStart,
                  onScaleUpdate: _onScaleUpdate,
                  onScaleEnd: _onScaleEnd,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      for (int s = 0; s < sections.length; s++) ...[
                        SliverPersistentHeader(
                          pinned: false,
                          floating: false,
                          delegate: _DateHeaderDelegate(sections[s].label),
                        ),
                        SliverGrid(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: effectiveColumnCount,
                            crossAxisSpacing: 1.5,
                            mainAxisSpacing: 1.5,
                          ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final file = sections[s].files[index];
                            int globalIndex = 0;
                            for (int prev = 0; prev < s; prev++) {
                              globalIndex += sections[prev].files.length;
                            }
                            globalIndex += index;
                            final isSelected = _selectedIds.contains(file.id);

                            return GestureDetector(
                              onTap: () async {
                                if (_selectionMode) {
                                  _toggleSelected(file.id);
                                  return;
                                }
                                final result = await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ImageViewerScreen(
                                      files: flatFiles,
                                      initialIndex: globalIndex,
                                    ),
                                  ),
                                );
                                if (result == true) _refresh();
                              },
                              onLongPress: () => _enterSelection(file.id),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  GalleryGridItem(
                                      key: ValueKey(file.id), file: file),
                                  if (_selectionMode)
                                    Container(
                                      color: isSelected
                                          ? t.scrim
                                          : Colors.transparent,
                                      child: Align(
                                        alignment: Alignment.topRight,
                                        child: Padding(
                                          padding:
                                              const EdgeInsets.all(4.0),
                                          child: ThemeIcon(
                                            isSelected
                                                ? 'checkCircle'
                                                : 'radio_button_unchecked',
                                            selected: isSelected,
                                            color: Colors.white,
                                            size: 22,
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (!_selectionMode && file.isFavorite)
                                    Positioned(
                                      top: 4,
                                      left: 4,
                                      child: ThemeIcon(
                                        'heart',
                                        selected: true,
                                        size: 14,
                                        color: cs.error,
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                          childCount: sections[s].files.length,
                        ),
                      ),
                    ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildToolbar(List<CnestFile> all) {
    final cs = Theme.of(context).colorScheme;
    if (_selectionMode) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        color: cs.surfaceContainerHighest,
        child: Row(
          children: [
            IconButton(
              icon: ThemeIcon('x'),
              onPressed: _exitSelection,
            ),
            const SizedBox(width: 4),
            Text(
              '${_selectedIds.length} selected',
              style: TextStyle(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            IconButton(
              icon: ThemeIcon('shareFat'),
              onPressed: () => _shareSelectedFilenames(all),
            ),
            IconButton(
              icon: ThemeIcon(
                'trash',
                color: cs.error,
              ),
              onPressed: () => _deleteSelected(all),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          FilterChip(
            label: const Text('Favorites'),
            avatar: ThemeIcon(
              'heart',
              selected: _favoritesOnly,
              size: 14,
              color: _favoritesOnly ? cs.error : cs.onSurface,
            ),
            selected: _favoritesOnly,
            onSelected: (v) {
              setState(() => _favoritesOnly = v);
              _refresh();
            },
          ),
          const Spacer(),
          Text(
            '${all.length} photo${all.length == 1 ? '' : 's'}',
            style: TextStyle(
              color: cs.onSurface.withAlpha(140),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _DateHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String label;
  _DateHeaderDelegate(this.label);

  @override
  double get minExtent => 36;
  @override
  double get maxExtent => 36;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text(
        label,
        style: TextStyle(
          color: cs.onSurface.withAlpha(180),
          fontSize: 13,
          fontWeight: FontWeight.w600,
          fontFamily: t.fontFamily,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _DateHeaderDelegate oldDelegate) =>
      label != oldDelegate.label;
}

/// Shared thumbnail grid item — used by Pictures tab, Albums detail, etc.
class GalleryGridItem extends StatefulWidget {
  final CnestFile file;
  const GalleryGridItem({super.key, required this.file});

  @override
  State<GalleryGridItem> createState() => _GalleryGridItemState();
}

class _GalleryGridItemState extends State<GalleryGridItem> {
  // Rung 1: MediaStore thumbnail bytes, held in state so Flutter's image
  // cache hits across rebuilds (MemoryImage equality is by reference).
  Uint8List? _assetThumbBytes;
  // Rung 3: path to a decrypted thumbnail file we wrote into the temp cache.
  String? _diskThumbPath;
  bool _loading = true;
  bool _isVideo = false;
  bool _wipedCorruptThumb = false;
  // Set only when the local original passed LocalContentGuard (content, not
  // just presence). build() renders Image.file only when this is true, so a
  // stale/mismatched local file never masquerades as the vault entry.
  bool _localVerified = false;
  // A just-synced file whose blob isn't downloadable yet (cloud eventual
  // consistency, or size/hash not joined). Drives a calm "Syncing…" tile
  // that auto-retries on the next sync — never a broken/error tile.
  bool _syncing = false;

  /// A corrupt cached thumb (partial write, interrupted decrypt) would
  /// otherwise error-paint forever. Delete it once and re-fetch; if the
  /// re-fetch is corrupt too, we settle for the plain placeholder.
  void _handleCorruptDiskThumb() {
    if (_wipedCorruptThumb || _diskThumbPath == null) return;
    _wipedCorruptThumb = true;
    final path = _diskThumbPath!;
    Future.microtask(() async {
      try {
        await File(path).delete();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _diskThumbPath = null;
          _loading = true;
        });
        _loadThumbnail();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    final ext = widget.file.filename.split('.').last.toLowerCase();
    _isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(ext);
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    if (!mounted) return;

    // RUNG 1: Android's MediaStore — same drawer Samsung Gallery reads from.
    if (widget.file.assetId != null) {
      try {
        final asset = await AssetEntity.fromId(widget.file.assetId!);
        if (asset != null &&
            await LocalContentGuard.matches(widget.file, asset: asset)) {
          final bytes = await asset.thumbnailDataWithSize(
            const ThumbnailSize(300, 300),
          );
          if (bytes != null) {
            // Opportunistic reclaim: if we previously fetched + decrypted
            // this file from the cloud (leaving `thumb_*.jpg` and
            // `*_decrypted.jpg` in temp), those artifacts are dead weight
            // now that MediaStore is serving us. Wipe them so the cache
            // shrinks the moment the local gallery entry comes back.
            unawaited(CacheManagerService().invalidateFile(
              fileId: widget.file.id,
              cloudId: widget.file.cloudId,
              thumbnailCloudId: widget.file.thumbnailCloudId,
            ));
            if (mounted) {
              setState(() {
                _assetThumbBytes = bytes;
                _loading = false;
              });
            }
            return;
          }
        }
      } catch (_) {
        // Asset gone / permission revoked — fall through.
      }
    }

    // RUNG 2: local original via Flutter's image decoder (downsamples at
    // decode time on the IO thread). No state needed — build() returns
    // Image.file directly when localPath is set.
    if (!_isVideo && widget.file.localPath != null) {
      final localFile = File(widget.file.localPath!);
      if (await localFile.exists() &&
          await LocalContentGuard.matches(widget.file, localFile: localFile)) {
        // Same reclaim as rung 1 — local file is authoritative now, the
        // encrypted-cache copy is redundant.
        unawaited(CacheManagerService().invalidateFile(
          fileId: widget.file.id,
          cloudId: widget.file.cloudId,
          thumbnailCloudId: widget.file.thumbnailCloudId,
        ));
        if (mounted) {
          setState(() {
            _localVerified = true;
            _loading = false;
          });
        }
        return;
      }
    }

    // RUNG 3: encrypted thumb from cloud, decrypted once into the temp cache.
    if (_isVideo && widget.file.thumbnailCloudId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    try {
      final cacheDir = await getTemporaryDirectory();
      final targetCloudId =
          widget.file.thumbnailCloudId ?? widget.file.cloudId;
      // No blob joined yet. If the row carries op identity (content hash /
      // known size), a peer's createFile op arrived but the blob is still
      // propagating (normal on the receiving device) → calm "Syncing…",
      // auto-retried next sync. Otherwise it's a true phantom → broken tile.
      if (targetCloudId == null) {
        final stillPropagating =
            widget.file.contentHash != null || widget.file.sizeBytes > 0;
        if (mounted) {
          setState(() {
            _syncing = stillPropagating;
            _loading = false;
          });
        }
        return;
      }

      final isThumbnail = widget.file.thumbnailCloudId != null;
      final fileName = isThumbnail
          ? 'thumb_${widget.file.cloudId}.jpg'
          : '${widget.file.cloudId}_decrypted.jpg';
      final cacheFile = File('${cacheDir.path}/$fileName');

      if (!await cacheFile.exists()) {
        final encryptedBytes =
            await CloudService().downloadFile(targetCloudId);
        final decryptedBytes =
            await EncryptionService.decryptFile(encryptedBytes);
        // Never cache an empty/implausible result — a momentarily-absent
        // blob would otherwise stick as a permanent 0-byte tile. Leaving the
        // cache unwritten means the next sync re-fetches.
        if (decryptedBytes.isEmpty) {
          if (mounted) {
            setState(() {
              _syncing = true;
              _loading = false;
            });
          }
          return;
        }
        await cacheFile.writeAsBytes(decryptedBytes, flush: true);
      }

      if (mounted) {
        setState(() {
          _diskThumbPath = cacheFile.path;
          _syncing = false;
          _loading = false;
        });
      }
    } catch (e) {
      // Download/decrypt failed (often eventual-consistency on a just-synced
      // blob). Calm "Syncing…", retried next sync — nothing was cached.
      if (mounted) {
        setState(() {
          _syncing = true;
          _loading = false;
        });
      }
    }
  }

  Widget _videoOverlay(ColorScheme cs) {
    // Small corner badge. A big centered play glyph reads as a tappable
    // control and covers the thumbnail — this just *labels* it as a video.
    return Positioned(
      left: 5,
      bottom: 5,
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: ThemeController().tokens.scrim,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: ThemeIcon(
            'play',
            selected: true,
            size: 13,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget errorTile(_, _, _) =>
        Container(color: cs.surfaceContainerHighest);

    // Rung 1 — MediaStore bytes.
    if (_assetThumbBytes != null) {
      return Stack(fit: StackFit.expand, children: [
        Image.memory(
          _assetThumbBytes!,
          fit: BoxFit.cover,
          errorBuilder: errorTile,
        ),
        if (_isVideo) _videoOverlay(cs),
      ]);
    }

    // Rung 2 — local original, Flutter decodes at cacheWidth. Only when the
    // content guard verified it (set in _loadThumbnail); a bare localPath is
    // not enough — it might point at stale/different bytes.
    if (!_isVideo && _localVerified && widget.file.localPath != null) {
      final localFile = File(widget.file.localPath!);
      if (localFile.existsSync()) {
        return Stack(fit: StackFit.expand, children: [
          Image.file(
            localFile,
            fit: BoxFit.cover,
            cacheWidth: 300,
            gaplessPlayback: true,
            errorBuilder: errorTile,
          ),
          if (_isVideo) _videoOverlay(cs),
        ]);
      }
    }

    // Rung 3 — decrypted thumb on disk.
    if (_diskThumbPath != null) {
      return Stack(fit: StackFit.expand, children: [
        Image.file(
          File(_diskThumbPath!),
          fit: BoxFit.cover,
          cacheWidth: 300,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) {
            _handleCorruptDiskThumb();
            return errorTile(context, error, stackTrace);
          },
        ),
        if (_isVideo) _videoOverlay(cs),
      ]);
    }

    // Still loading or no thumbnail available — solid placeholder.
    if (_loading) return Container(color: cs.surfaceContainerHighest);

    // Just-synced file whose blob isn't downloadable yet — a CALM
    // auto-resolving "Syncing…" tile, never a broken-image error. It fills in
    // on the next sync once the blob is available; on the receiving device a
    // briefly-absent blob is the normal case, not corruption.
    if (_syncing) {
      return Container(
        color: cs.surfaceContainerHighest,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ThemeIcon('arrowsClockwise',
                  color: cs.onSurface.withAlpha(120), size: 26),
              const SizedBox(height: 6),
              Text('Syncing…',
                  style: TextStyle(
                      color: cs.onSurface.withAlpha(120), fontSize: 11)),
            ],
          ),
        ),
      );
    }

    return Container(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: ThemeIcon(
          _isVideo ? 'playCircle' : 'imageBroken',
          color: cs.onSurface.withAlpha(140),
          size: 40,
        ),
      ),
    );
  }
}
