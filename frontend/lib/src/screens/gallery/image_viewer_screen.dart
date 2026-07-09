import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:async_wallpaper/async_wallpaper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import '../../widgets/theme_icon.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../../config/theme_controller.dart';
import '../../models/file_model.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/database_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/auto_sync_service.dart';
import '../../../services/file_metadata_service.dart';
import '../../../services/image_edit_service.dart';
import '../../../services/video_streaming_server.dart';
import '../share/share_dialog.dart';
import 'image_editor_screen.dart';

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
  // True while the user has their finger on the filmstrip (or it's still
  // settling from a fling). Suppresses _scrollToIndex echo-back so we don't
  // fight the user's drag.
  bool _userScrollingStrip = false;
  static final Set<String> _activeDownloads = {};
  // Zoom state of the focused page. While zoomed, page-swipe and
  // swipe-down-to-dismiss are disabled so drags pan the image instead.
  bool _isZoomed = false;
  // Swipe-up-for-details tracking: cumulative deltas of a single-finger
  // drag. A second finger (pinch) or a zoomed image locks the sheet out
  // for the rest of the gesture.
  int _activePointers = 0;
  double _dragDx = 0;
  double _dragDy = 0;
  bool _sheetTriggered = false;

  // --- Active-video binding, reported by the focused page. The dock uses it
  // to render the Samsung-style pill (play/pause + time), the mute toggle,
  // and the in-strip scrubber.
  VideoPlayerController? _activeVideo;
  Future<void> Function()? _activeVideoInit;
  int? _activeVideoIndex;
  // Samsung behavior: every video starts playing muted when you land on it.
  bool _videoMuted = true;
  // Tapping the centered video thumb expands it into a per-second frame
  // strip; the bar then scrolls under a FIXED center playhead to scrub.
  // Collapses on page change or when the scrub exits the segment.
  bool _videoExpanded = false;

  // --- Center-locked filmstrip geometry (Samsung) ---
  // Photos are 3:4, videos 4:3 (same height, wider), the expanded video is
  // one tile per second (capped). Slots have VARIABLE widths, so all offset
  // math walks slot widths instead of assuming a uniform extent.
  static const double _stripBarHeight = 56.0;
  static const double _thumbH = 40.0;
  static const double _photoSlot = 36.0; // 30 wide thumb + 6 margins
  static const double _videoSlot = 59.0; // 53 wide (4:3 of 40) + 6
  static const double _frameTileW = 44.0; // expanded per-second tile
  static const double _vSlot = 36.0; // landscape rail: uniform slots
  Axis _stripAxis = Axis.horizontal;
  // Captured by the strip's LayoutBuilder each build; the offset math needs
  // the real leading pad + viewport (pad clamps to 0 on small screens).
  double _stripLeadPad = 0;
  double _stripViewport = 0;

  static bool _isVideoFile(CnestFile f) {
    final ext = f.filename.split('.').last.toLowerCase();
    return const {'mp4', 'mov', 'avi', 'mkv'}.contains(ext);
  }

  /// Samsung shows ~1 frame per second, capped (52 s video → 12 frames).
  static int _expandedFrameCount(Duration d) =>
      d.inSeconds.clamp(1, 12).toInt();

  double _slotWidth(int index) {
    if (_stripAxis == Axis.vertical) return _vSlot;
    final f = _currentFiles[index];
    if (!_isVideoFile(f)) return _photoSlot;
    if (_videoExpanded && index == _currentIndex && _activeVideo != null) {
      return _expandedFrameCount(_activeVideo!.value.duration) * _frameTileW +
          6;
    }
    return _videoSlot;
  }

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

  /// Content-x where slot [index] begins (excluding the leading pad).
  double _slotStart(int index) {
    double x = 0;
    for (var i = 0; i < index; i++) {
      x += _slotWidth(i);
    }
    return x;
  }

  /// Scroll offset that puts slot [index]'s center under the bar's center.
  double _stripOffsetFor(int index) {
    final raw = _stripLeadPad +
        _slotStart(index) +
        _slotWidth(index) / 2 -
        _stripViewport / 2;
    return max(0.0, raw);
  }

  /// Which slot's center is nearest the bar's center at scroll [offset].
  int _indexForStripOffset(double offset) {
    if (_currentFiles.isEmpty) return 0;
    final centerX = offset + _stripViewport / 2 - _stripLeadPad;
    double x = 0;
    for (var i = 0; i < _currentFiles.length; i++) {
      final w = _slotWidth(i);
      if (centerX < x + w) return i;
      x += w;
    }
    return _currentFiles.length - 1;
  }

  void _scrollToIndex(int index) {
    if (!_filmStripController.hasClients) return;
    // While the user is driving the strip, do NOT animateTo — it would fight
    // their drag/fling and cause stuttering.
    if (_userScrollingStrip) return;
    _filmStripController.animateTo(
      _stripOffsetFor(index),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  /// Reads the strip's current scroll position, finds the item closest to
  /// screen-center, and jumps the main PageView to it. Called on every
  /// ScrollUpdateNotification while the user is dragging or the strip is
  /// settling from a fling — this is what makes scrolling the bar *change*
  /// the displayed photo instead of just panning past it.
  void _syncMainPageFromStrip() {
    if (!_filmStripController.hasClients || !_pageController.hasClients) return;
    final clamped = _indexForStripOffset(_filmStripController.offset);
    if (clamped == _currentIndex) return;
    // jumpToPage triggers onPageChanged which updates _currentIndex, but
    // _scrollToIndex inside that callback is suppressed by _userScrollingStrip.
    _pageController.jumpToPage(clamped);
  }

  /// Strip scroll dispatch: normally it drives page selection; while a video
  /// is EXPANDED the same drag scrubs playback under the fixed center
  /// playhead, and exiting the segment collapses back to selection mode.
  void _handleStripScrollUpdate() {
    if (!_videoExpanded || _stripAxis == Axis.vertical) {
      _syncMainPageFromStrip();
      return;
    }
    final controller = _activeVideo;
    if (controller == null || !_filmStripController.hasClients) {
      _syncMainPageFromStrip();
      return;
    }
    final centerX =
        _filmStripController.offset + _stripViewport / 2 - _stripLeadPad;
    final segStart = _slotStart(_currentIndex) + 3;
    final duration = controller.value.duration;
    final segWidth = _expandedFrameCount(duration) * _frameTileW;
    if (centerX < segStart - 12 || centerX > segStart + segWidth + 12) {
      // Scrubbed past the segment — collapse and let selection take over.
      setState(() => _videoExpanded = false);
      _syncMainPageFromStrip();
      return;
    }
    if (duration <= Duration.zero) return;
    final fraction = ((centerX - segStart) / segWidth).clamp(0.0, 1.0);
    controller.seekTo(duration * fraction);
  }

  /// After a drag/fling settles, lock the strip onto the nearest item so the
  /// current photo always sits exactly centered. (Not while a video is
  /// expanded — the scrub position IS the resting position.)
  void _snapStripToNearest() {
    if (!_filmStripController.hasClients || _videoExpanded) return;
    final index = _indexForStripOffset(_filmStripController.offset);
    final target = _stripOffsetFor(index);
    if ((target - _filmStripController.offset).abs() < 0.5) return;
    _filmStripController.animateTo(
      target,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  /// Scroll offset that puts playback-fraction [fraction] of the expanded
  /// segment under the fixed center playhead.
  double _stripOffsetForVideoFraction(double fraction) {
    final controller = _activeVideo;
    if (controller == null) return 0;
    final segStart = _slotStart(_currentIndex) + 3;
    final segWidth =
        _expandedFrameCount(controller.value.duration) * _frameTileW;
    final raw =
        _stripLeadPad + segStart + fraction * segWidth - _stripViewport / 2;
    if (!_filmStripController.hasClients) return max(0.0, raw);
    return raw.clamp(
      0.0,
      _filmStripController.position.maxScrollExtent,
    );
  }

  void _expandCurrentVideo() {
    final controller = _activeVideo;
    if (controller == null || _videoExpanded) return;
    setState(() => _videoExpanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_videoExpanded) return;
      final duration = controller.value.duration;
      final fraction = duration.inMilliseconds == 0
          ? 0.0
          : (controller.value.position.inMilliseconds /
                  duration.inMilliseconds)
              .clamp(0.0, 1.0);
      if (_filmStripController.hasClients) {
        _filmStripController.jumpTo(_stripOffsetForVideoFraction(fraction));
      }
    });
  }

  /// While an expanded video PLAYS, the bar glides under the fixed playhead
  /// (Samsung: the playhead never moves; the film moves).
  void _onActiveVideoTick() {
    if (!mounted || !_videoExpanded || _userScrollingStrip) return;
    final controller = _activeVideo;
    if (controller == null || !controller.value.isPlaying) return;
    if (!_filmStripController.hasClients) return;
    final duration = controller.value.duration;
    if (duration <= Duration.zero) return;
    final fraction = (controller.value.position.inMilliseconds /
            duration.inMilliseconds)
        .clamp(0.0, 1.0);
    _filmStripController.animateTo(
      _stripOffsetForVideoFraction(fraction),
      duration: const Duration(milliseconds: 250),
      curve: Curves.linear,
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

    // Pre-warm the thumbnail regardless of local-original presence so the
    // filmstrip and viewer placeholder are ready when the user swipes here.
    _prewarmThumb(file);

    // Skip full-image pre-fetch if the original is on device — Image.file
    // will pick it up instantly on swipe.
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

  Future<void> _prewarmThumb(CnestFile file) async {
    // Local videos: pre-extract a frame into the shared thumb cache while
    // the user is still on a neighboring page — extraction takes a few
    // hundred ms, which is exactly the filmstrip lag being hidden here.
    final ext = file.filename.split('.').last.toLowerCase();
    final isVideo = const {'mp4', 'mov', 'avi', 'mkv'}.contains(ext);
    if (isVideo &&
        file.cloudId != null &&
        file.localPath != null &&
        File(file.localPath!).existsSync()) {
      try {
        final cacheDir = await getTemporaryDirectory();
        final thumbFile = File('${cacheDir.path}/thumb_${file.cloudId}.jpg');
        if (!await thumbFile.exists()) {
          final bytes = await VideoThumbnail.thumbnailData(
            video: file.localPath!,
            imageFormat: ImageFormat.JPEG,
            maxWidth: 300,
            quality: 60,
          );
          if (bytes != null) await thumbFile.writeAsBytes(bytes);
        }
      } catch (_) {
        // Best-effort prewarm.
      }
      return;
    }

    // MediaStore thumbs are served from Android's cache, so just touching the
    // API warms the path. Skip the actual byte copy here — Filmstrip and the
    // viewer placeholder will request them lazily.
    if (file.assetId != null) return;

    // For cloud-only files, decrypt the encrypted thumb into the temp cache
    // so the viewer's first-frame placeholder is ready by the time the user
    // swipes onto this page.
    if (file.localPath != null && File(file.localPath!).existsSync()) return;
    if (file.thumbnailCloudId == null) return;

    try {
      final cacheDir = await getTemporaryDirectory();
      final thumbFile = File('${cacheDir.path}/thumb_${file.cloudId}.jpg');
      if (await thumbFile.exists()) return;

      final encryptedBytes =
          await CloudService().downloadFile(file.thumbnailCloudId!);
      if (!mounted) return;
      final decryptedBytes = await EncryptionService.decryptFile(encryptedBytes);
      await thumbFile.writeAsBytes(decryptedBytes);
    } catch (_) {
      // Silent
    }
  }

  // --- DELETE LOGIC ---
  // Soft-delete: the encrypted blob and decrypted cache stay put for 30 days
  // so restores are instant and offline. RecycleBinService.sweepRecycleBin
  // wipes them at TTL.
  Future<void> _handleDelete() async {
    final fileToDelete = _currentFiles[_currentIndex];
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move to Recycle Bin?'),
        content: const Text(
          'The file will be hidden from your gallery and permanently deleted '
          'after 30 days. You can restore it from Settings > Recycle Bin.',
        ),
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
      await DatabaseService().deleteFile(fileToDelete.id);
      AutoSyncService.trackDeletion(fileToDelete.filename, fileToDelete.sizeBytes);
      DatabaseBackupService().scheduleBackup();

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
        ).showSnackBar(const SnackBar(content: Text('Moved to Recycle Bin')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  Future<void> _toggleFavorite() async {
    if (_currentFiles.isEmpty) return;
    final file = _currentFiles[_currentIndex];
    final next = !file.isFavorite;
    await DatabaseService().setFavorite(file.id, next);
    final updated = CnestFile(
      id: file.id,
      cloudId: file.cloudId,
      thumbnailCloudId: file.thumbnailCloudId,
      provider: file.provider,
      accountId: file.accountId,
      filename: file.filename,
      sizeBytes: file.sizeBytes,
      createdAt: file.createdAt,
      isUploaded: file.isUploaded,
      localPath: file.localPath,
      assetId: file.assetId,
      isFavorite: next,
      type: file.type,
    );
    setState(() => _currentFiles[_currentIndex] = updated);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(next ? 'Added to favorites' : 'Removed from favorites')),
      );
    }
  }

  /// Opens the info-sheet's Edit dialog: rename + change captured date/time
  /// in one flow. Returns true if either field was actually changed.
  Future<bool> _showEditInfo(CnestFile file) async {
    final result = await showDialog<_EditInfoResult>(
      context: context,
      builder: (_) => _EditInfoDialog(file: file),
    );
    if (result == null) return false;
    if (result.filename != file.filename) {
      await DatabaseService().renameFile(file.id, result.filename);
    }
    if (result.captured != file.createdAt) {
      await DatabaseService().updateCreatedAt(file.id, result.captured);
    }
    // Refresh the in-viewer copy so the AppBar title + info sheet reflect
    // the changes without a pop-and-rebuild. Live-updated fields are
    // filename + createdAt; everything else is copied over unchanged.
    final updated = CnestFile(
      id: file.id,
      cloudId: file.cloudId,
      thumbnailCloudId: file.thumbnailCloudId,
      provider: file.provider,
      accountId: file.accountId,
      filename: result.filename,
      sizeBytes: file.sizeBytes,
      createdAt: result.captured,
      isUploaded: file.isUploaded,
      localPath: file.localPath,
      assetId: file.assetId,
      isFavorite: file.isFavorite,
      type: file.type,
    );
    if (mounted) {
      setState(() => _currentFiles[_currentIndex] = updated);
    }
    return true;
  }

  /// Returns true if the current file is a video and the Edit button should
  /// be hidden.
  bool get _currentIsVideo {
    if (_currentFiles.isEmpty) return false;
    final ext = _currentFiles[_currentIndex]
        .filename
        .split('.')
        .last
        .toLowerCase();
    return const {'mp4', 'mov', 'avi', 'mkv'}.contains(ext);
  }

  Future<void> _openEditor() async {
    if (_currentFiles.isEmpty) return;
    final source = _currentFiles[_currentIndex];
    final messenger = ScaffoldMessenger.of(context);

    final loaded = await _currentImageBytes();
    if (loaded == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not load image to edit')),
      );
      return;
    }

    // Pre-flight: HEIC bytes break the editor's decoder. Re-encode to JPG.
    Uint8List forEditor = loaded;
    if (_looksLikeHeic(source.filename, loaded)) {
      try {
        forEditor = await FlutterImageCompress.compressWithList(
          loaded,
          quality: 90,
        );
      } catch (_) {
        // Best-effort; fall through and let the editor surface its own error.
      }
    }

    // Memory: 12 MP RGBA ≈ 48 MB; editor working buffers triple that. Keep
    // any longest-edge >2048 px downsampled so we don't OOM low-end devices.
    if (forEditor.length > 3 * 1024 * 1024) {
      try {
        forEditor = await FlutterImageCompress.compressWithList(
          forEditor,
          minWidth: 2048,
          minHeight: 2048,
          quality: 90,
        );
      } catch (_) {
        // Best-effort; we just hand the original bytes to the editor.
      }
    }

    if (!mounted) return;
    final Uint8List? edited = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => ImageEditorScreen(bytes: forEditor)),
    );
    if (edited == null) return; // User cancelled.

    if (!mounted) return;
    final mode = await _showSaveSheet(source);
    if (mode == null) return; // Dismissed the save sheet.

    // Show a blocking progress overlay during encrypt + upload. The encrypt
    // step is CPU-bound and the upload is network — we don't want the user
    // bouncing back into the viewer with a half-saved file.
    _showProcessingDialog();
    try {
      final result = await ImageEditService().saveEdit(
        source: source,
        editedBytes: edited,
        replaceOriginal: mode == _SaveMode.replace,
      );
      if (!mounted) return;
      Navigator.of(context).pop(); // dismiss progress

      setState(() {
        if (mode == _SaveMode.replace) {
          _currentFiles[_currentIndex] = result;
        } else {
          // Save-as-copy: insert at the next index so the user sees their
          // new edit immediately after the original.
          final insertAt = (_currentIndex + 1).clamp(0, _currentFiles.length);
          _currentFiles.insert(insertAt, result);
          _currentIndex = insertAt;
          _pageController.jumpToPage(insertAt);
        }
        _hasDeleted = true; // re-using the gallery-refresh flag
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            mode == _SaveMode.replace ? 'Photo replaced' : 'Edited copy saved',
          ),
        ),
      );
    } catch (e) {
      if (mounted) Navigator.of(context).pop(); // dismiss progress
      messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  Future<_SaveMode?> _showSaveSheet(CnestFile source) async {
    final cs = Theme.of(context).colorScheme;
    final isCameraRoll = source.assetId != null;
    final isUnsyncedVaultFile =
        source.cloudId == null || !source.isUploaded;
    // We can only replace when the source is a vault file already in cloud
    // and isn't a camera-roll original we'd be overwriting in spirit.
    final canReplace = !isCameraRoll && !isUnsyncedVaultFile;

    return showModalBottomSheet<_SaveMode>(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 18),
                    decoration: BoxDecoration(
                      color: Colors.grey[600],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  'Save edit',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                _SaveOptionTile(
                  icon: themeIconData('copy'),
                  title: 'Save as copy',
                  subtitle:
                      'Keep the original. Recommended — original stays intact.',
                  onTap: () => Navigator.pop(ctx, _SaveMode.copy),
                ),
                const SizedBox(height: 10),
                _SaveOptionTile(
                  icon: themeIconData('arrowsClockwise'),
                  title: 'Replace original',
                  subtitle: canReplace
                      ? 'Delete the original and keep only the edit.'
                      : isCameraRoll
                          ? 'Unavailable for camera-roll photos — we never '
                              'overwrite your gallery.'
                          : 'Unavailable — original isn\'t synced to cloud yet.',
                  enabled: canReplace,
                  onTap: canReplace
                      ? () => Navigator.pop(ctx, _SaveMode.replace)
                      : null,
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showProcessingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Material(
            color: Colors.transparent,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: Colors.white),
                SizedBox(height: 16),
                Text(
                  'Encrypting & uploading…',
                  style: TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _looksLikeHeic(String filename, Uint8List bytes) {
    final ext = filename.split('.').last.toLowerCase();
    if (ext == 'heic' || ext == 'heif') return true;
    // ftyp box at offset 4..7 + heic/heix/mif1 brand
    if (bytes.length < 12) return false;
    if (bytes[4] != 0x66 || bytes[5] != 0x74 ||
        bytes[6] != 0x79 || bytes[7] != 0x70) {
      return false;
    }
    final brand = String.fromCharCodes(bytes.sublist(8, 12));
    return brand == 'heic' || brand == 'heix' || brand == 'mif1';
  }

  Future<Uint8List?> _currentImageBytes() async {
    if (_currentFiles.isEmpty) return null;
    final file = _currentFiles[_currentIndex];
    if (file.localPath != null) {
      final f = File(file.localPath!);
      if (await f.exists()) return f.readAsBytes();
    }
    if (file.cloudId == null) return null;
    final tempDir = await getTemporaryDirectory();
    final cached = File('${tempDir.path}/${file.cloudId}_decrypted.jpg');
    if (await cached.exists()) return cached.readAsBytes();
    final encrypted = await CloudService().downloadFile(file.cloudId!);
    return EncryptionService.decryptFile(encrypted);
  }

  Future<void> _copyToClipboard() async {
    if (_currentFiles.isEmpty) return;
    final file = _currentFiles[_currentIndex];
    final messenger = ScaffoldMessenger.of(context);
    final isImage = file.type == CnestFileType.image &&
        !['mp4', 'mov', 'avi', 'mkv']
            .contains(file.filename.split('.').last.toLowerCase());
    try {
      if (isImage) {
        final bytes = await _currentImageBytes();
        if (bytes == null) throw Exception('Could not load image');
        await Pasteboard.writeImage(bytes);
        messenger.showSnackBar(
          const SnackBar(content: Text('Image copied to clipboard')),
        );
      } else {
        await Clipboard.setData(ClipboardData(text: file.filename));
        messenger.showSnackBar(
          const SnackBar(content: Text('Filename copied to clipboard')),
        );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Copy failed: $e')));
    }
  }

  Future<void> _printCurrent() async {
    if (_currentFiles.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    // Video bytes can't be laid out as a PDF image — same "Invalid image
    // data" failure as the thumbnail path.
    if (_currentIsVideo) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Videos can't be printed")),
      );
      return;
    }
    try {
      final bytes = await _currentImageBytes();
      if (bytes == null) throw Exception('Could not load image');
      await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async {
          final doc = pw.Document();
          final image = pw.MemoryImage(bytes);
          doc.addPage(
            pw.Page(
              pageFormat: format,
              build: (ctx) => pw.Center(child: pw.Image(image)),
            ),
          );
          return doc.save();
        },
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Print failed: $e')));
    }
  }

  /// Set the current photo as Android wallpaper. Decrypts in-memory, writes to
  /// the app's private temp dir, hands the path to AsyncWallpaper, then wipes
  /// the temp file. The wallpaper manager is an in-app sink — no public-storage
  /// or share-intent leak of plaintext bytes.
  Future<void> _setAsWallpaper() async {
    if (_currentFiles.isEmpty) return;
    final file = _currentFiles[_currentIndex];
    final messenger = ScaffoldMessenger.of(context);

    final ext = file.filename.split('.').last.toLowerCase();
    if (const {'mp4', 'mov', 'avi', 'mkv'}.contains(ext)) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Videos can't be set as wallpaper")),
      );
      return;
    }

    final location = await _showWallpaperLocationSheet();
    if (location == null) return;

    File? tempFile;
    try {
      final bytes = await _currentImageBytes();
      if (bytes == null) throw Exception('Could not load image');
      final tempDir = await getTemporaryDirectory();
      tempFile = File('${tempDir.path}/_wallpaper_tmp.jpg');
      await tempFile.writeAsBytes(bytes);

      await AsyncWallpaper.setWallpaperFromFile(tempFile.path, location);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('Wallpaper set')));
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      try {
        if (tempFile != null && await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (_) {
        // best-effort cleanup
      }
    }
  }

  Future<int?> _showWallpaperLocationSheet() {
    final cs = Theme.of(context).colorScheme;
    return showModalBottomSheet<int>(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 18),
                    decoration: BoxDecoration(
                      color: Colors.grey[600],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  'Set as wallpaper',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                _SaveOptionTile(
                  icon: themeIconData('house'),
                  title: 'Home screen',
                  subtitle: 'Apply only to the home screen.',
                  onTap: () =>
                      Navigator.pop(ctx, AsyncWallpaper.HOME_SCREEN),
                ),
                const SizedBox(height: 10),
                _SaveOptionTile(
                  icon: themeIconData('lockKey'),
                  title: 'Lock screen',
                  subtitle: 'Apply only to the lock screen.',
                  onTap: () =>
                      Navigator.pop(ctx, AsyncWallpaper.LOCK_SCREEN),
                ),
                const SizedBox(height: 10),
                _SaveOptionTile(
                  icon: themeIconData('devices'),
                  title: 'Both',
                  subtitle: 'Apply to both home and lock screens.',
                  onTap: () =>
                      Navigator.pop(ctx, AsyncWallpaper.BOTH_SCREENS),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showDetailsSheet() {
    final file = _currentFiles[_currentIndex];
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.3,
        maxChildSize: 0.85,
        expand: false,
        builder: (_, controller) => _InfoSheetBody(
          file: file,
          scrollController: controller,
          onEdit: () async {
            final changed = await _showEditInfo(file);
            // Sheet's own BuildContext (`ctx`) — safe to pop once we know
            // the sheet is still mounted. Bouncing it closed forces a
            // fresh open to re-read the updated filename / capture date.
            if (!changed) return;
            if (!ctx.mounted) return;
            Navigator.of(ctx).pop();
          },
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
                  icon: ThemeIcon('arrowLeft'),
                  onPressed: () => Navigator.pop(context, _hasDeleted),
                ),
                actions: [
                  IconButton(
                    icon: ThemeIcon('arrowsCounterClockwise'),
                    onPressed: () {},
                  ),
                  PopupMenuButton<String>(
                    icon: ThemeIcon('dotsThreeVertical', color: overlayColor),
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
                    onSelected: (val) {
                      switch (val) {
                        case 'copy':
                          _copyToClipboard();
                          break;
                        case 'wall':
                          _setAsWallpaper();
                          break;
                        case 'print':
                          _printCurrent();
                          break;
                      }
                    },
                  ),
                ],
              )
            : null,

        body: OrientationBuilder(
          builder: (context, orientation) {
            final isLandscape = orientation == Orientation.landscape;
            // In landscape the controls live in a vertical rail on the right
            // (80 px). Shrink the photo area so it never sits behind the rail.
            final photoRightPadding =
                isLandscape && _showControls ? 80.0 : 0.0;
            return Stack(
              children: [
                // --- MAIN PHOTO AREA ---
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  right: photoRightPadding,
                  child: Listener(
                    onPointerDown: (_) {
                      _activePointers++;
                      _dragDx = 0;
                      _dragDy = 0;
                      // Multi-touch means pinch — never the details sheet.
                      if (_activePointers > 1) _sheetTriggered = true;
                    },
                    onPointerMove: (event) {
                      if (_sheetTriggered || _isZoomed || _activePointers != 1) {
                        return;
                      }
                      _dragDx += event.delta.dx;
                      _dragDy += event.delta.dy;
                      // Deliberate swipe-up: far enough, and clearly more
                      // vertical than horizontal.
                      if (_dragDy < -60 && _dragDy.abs() > _dragDx.abs() * 1.5) {
                        _sheetTriggered = true;
                        _showDetailsSheet();
                      }
                    },
                    onPointerUp: (_) {
                      _activePointers = max(0, _activePointers - 1);
                      if (_activePointers == 0) _sheetTriggered = false;
                    },
                    onPointerCancel: (_) {
                      _activePointers = max(0, _activePointers - 1);
                      if (_activePointers == 0) _sheetTriggered = false;
                    },
                    child: GestureDetector(
                      onTap: () =>
                          setState(() => _showControls = !_showControls),
                      child: Dismissible(
                        key: const Key('viewer_dismiss'),
                        // Swipe down to dismiss — unless zoomed in, when the
                        // drag must pan the image instead.
                        direction: _isZoomed
                            ? DismissDirection.none
                            : DismissDirection.down,
                        onDismissed: (direction) =>
                            Navigator.pop(context, _hasDeleted),
                        child: PageView.builder(
                          controller: _pageController,
                          // While zoomed, horizontal drags pan the image, not
                          // the pager.
                          physics: _isZoomed
                              ? const NeverScrollableScrollPhysics()
                              : null,
                          itemCount: _currentFiles.length,
                          onPageChanged: (index) {
                            setState(() {
                              _currentIndex = index;
                              // New page starts unzoomed (the old page resets
                              // its own transform on losing focus).
                              _isZoomed = false;
                              // Samsung: expansion never survives a page
                              // change, and every video lands muted.
                              _videoExpanded = false;
                              _videoMuted = true;
                            });
                            // FIX: Sync filmstrip when swiping main photo
                            _scrollToIndex(index);
                          },
                          itemBuilder: (context, index) {
                            return Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 2.5),
                              child: _SinglePhotoView(
                                key: ValueKey(_currentFiles[index].id),
                                file: _currentFiles[index],
                                index: index,
                                onLoaded: (loadedIdx) =>
                                    _handleCurrentPhotoLoaded(loadedIdx),
                                isFocused: index == _currentIndex,
                                onZoomChanged: (zoomed) {
                                  if (_isZoomed == zoomed) return;
                                  // Post-frame: the child can report during
                                  // its didUpdateWidget, mid-build.
                                  WidgetsBinding.instance
                                      .addPostFrameCallback((_) {
                                    if (!mounted || _isZoomed == zoomed) return;
                                    setState(() => _isZoomed = zoomed);
                                  });
                                },
                                onVideoBinding: _onVideoBinding,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),

                // --- CONTROLS ---
                if (_showControls)
                  isLandscape
                      ? _buildLandscapeControls(theme, overlayColor)
                      : _buildPortraitControls(theme, overlayColor),
              ],
            );
          },
        ),
      ),
    );
  }

  // ---- Portrait: (video pill row when a video is current), gallery bar,
  // floating action bar. Only the action bar has a translucent background —
  // the pill and the bar float directly over the photo (Samsung).
  Widget _buildPortraitControls(ThemeData theme, Color overlayColor) {
    final tokens = ThemeController().tokens;
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_currentIsVideo)
              _buildVideoPillRow(overlayColor, vertical: false),
            SizedBox(
              height: _stripBarHeight,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: _buildFilmstrip(axis: Axis.horizontal),
                  ),
                  // Fixed center playhead: in expanded mode the FILM moves,
                  // the line doesn't (Samsung).
                  if (_videoExpanded && _activeVideo != null)
                    IgnorePointer(
                      child: Container(
                        width: 2.5,
                        height: _thumbH + 14,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(tokens.rPill),
              ),
              child: _buildActionButtons(
                overlayColor: overlayColor,
                vertical: false,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Landscape: 80 px right-side rail. Vertical strip is kept simple
  // (uniform slots, no expansion) — landscape polish is post-launch scope.
  Widget _buildLandscapeControls(ThemeData theme, Color overlayColor) {
    final tokens = ThemeController().tokens;
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      child: SizedBox(
        width: 80,
        child: SafeArea(
          left: false,
          child: Column(
            children: [
              if (_currentIsVideo)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _buildVideoPillRow(overlayColor, vertical: true),
                ),
              Expanded(
                child: _buildFilmstrip(axis: Axis.vertical),
              ),
              Container(
                margin: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.88),
                  borderRadius: BorderRadius.circular(tokens.rPill),
                ),
                child: _buildActionButtons(
                  overlayColor: overlayColor,
                  vertical: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Samsung-style video controls: frame-capture on the left, the
  // play/pause + time pill centered, mute on the right. All translucent,
  // floating straight over the photo.
  Widget _buildVideoPillRow(Color overlayColor, {required bool vertical}) {
    final pill = _VideoPill(
      controller: _activeVideo,
      vertical: vertical,
      onPlayPause: _handlePlayPause,
    );
    final capture = _GlassIconButton(
      icon: 'screenshotFrame',
      onTap: _captureVideoFrame,
    );
    final mute = _GlassIconButton(
      icon: _videoMuted ? 'speakerSlash' : 'speakerHigh',
      onTap: _toggleMute,
    );
    if (vertical) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          pill,
          const SizedBox(height: 6),
          capture,
          const SizedBox(height: 6),
          mute,
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          SizedBox(width: 44, child: Center(child: capture)),
          Expanded(child: Center(child: pill)),
          SizedBox(width: 44, child: Center(child: mute)),
        ],
      ),
    );
  }

  /// Samsung's frame-capture button: grabs the frame at the current playback
  /// position and saves it to the vault as a new encrypted image. The
  /// plaintext frame lives only in memory — never public storage.
  Future<void> _captureVideoFrame() async {
    final file = _currentFiles[_currentIndex];
    final controller = _activeVideo;
    final messenger = ScaffoldMessenger.of(context);
    try {
      String? source;
      if (file.localPath != null && File(file.localPath!).existsSync()) {
        source = file.localPath;
      } else {
        // Loopback streaming URL — the extractor range-requests our server,
        // which serves from its decrypted chunk cache.
        source = controller?.dataSource;
      }
      if (source == null) throw Exception('video is still loading');

      final bytes = await VideoThumbnail.thumbnailData(
        video: source,
        imageFormat: ImageFormat.JPEG,
        timeMs: controller?.value.position.inMilliseconds ?? 0,
        quality: 90,
      );
      if (bytes == null) throw Exception('could not extract the frame');

      final saved = await ImageEditService().saveEdit(
        source: file,
        editedBytes: bytes,
        replaceOriginal: false,
        copyLabel: 'frame',
      );
      if (!mounted) return;
      setState(() {
        final insertAt = (_currentIndex + 1).clamp(0, _currentFiles.length);
        _currentFiles.insert(insertAt, saved);
        _hasDeleted = true; // reuse the gallery-refresh flag
      });
      messenger.showSnackBar(
        const SnackBar(content: Text('Frame saved to vault')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Capture failed: $e')));
    }
  }

  Future<void> _handlePlayPause() async {
    final controller = _activeVideo;
    if (controller == null) {
      // Not initialized yet — ask the focused page to spin up playback.
      await _activeVideoInit?.call();
      await _activeVideo?.setVolume(_videoMuted ? 0 : 1);
      return;
    }
    final value = controller.value;
    if (value.isPlaying) {
      controller.pause();
    } else {
      if (value.duration > Duration.zero && value.position >= value.duration) {
        await controller.seekTo(Duration.zero);
      }
      controller.play();
    }
  }

  void _toggleMute() {
    setState(() => _videoMuted = !_videoMuted);
    _activeVideo?.setVolume(_videoMuted ? 0 : 1);
  }

  /// The focused page reports its video controller + init handler here.
  /// (index, null, null) means that page's video is gone — only honored if
  /// it's the page we're currently bound to, so a disposing off-screen page
  /// can't clobber the new page's binding.
  void _onVideoBinding(
    int index,
    VideoPlayerController? controller,
    Future<void> Function()? initHandler,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (controller == null && initHandler == null) {
        if (_activeVideoIndex == index) {
          _activeVideo?.removeListener(_onActiveVideoTick);
          setState(() {
            _activeVideo = null;
            _activeVideoInit = null;
            _activeVideoIndex = null;
            _videoExpanded = false;
          });
        }
        return;
      }
      if (index != _currentIndex) return;
      if (identical(_activeVideo, controller) &&
          _activeVideoInit == initHandler) {
        return;
      }
      _activeVideo?.removeListener(_onActiveVideoTick);
      setState(() {
        _activeVideo = controller;
        _activeVideoInit = initHandler;
        _activeVideoIndex = index;
      });
      controller?.addListener(_onActiveVideoTick);
      controller?.setVolume(_videoMuted ? 0 : 1);
    });
  }

  Widget _buildFilmstrip({required Axis axis}) {
    _stripAxis = axis;
    // Small-element radius comes from the active theme pack (Hackerman is
    // square, Burrow is round, etc.) — capped so tiny thumbs stay legible.
    final double thumbRadius = min(ThemeController().tokens.rIc, 10.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = axis == Axis.horizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
        _stripViewport = viewport;
        final leadPad = _currentFiles.isEmpty
            ? 0.0
            : max(0.0, (viewport - _slotWidth(0)) / 2);
        final trailPad = _currentFiles.isEmpty
            ? 0.0
            : max(0.0,
                (viewport - _slotWidth(_currentFiles.length - 1)) / 2);
        _stripLeadPad = leadPad;

        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollStartNotification &&
                notification.dragDetails != null) {
              _userScrollingStrip = true;
            } else if (notification is ScrollEndNotification) {
              final wasUser = _userScrollingStrip;
              _userScrollingStrip = false;
              if (wasUser) _snapStripToNearest();
            }
            if (notification is ScrollUpdateNotification &&
                _userScrollingStrip) {
              _handleStripScrollUpdate();
            }
            return false;
          },
          child: ListView.builder(
            controller: _filmStripController,
            scrollDirection: axis,
            itemCount: _currentFiles.length,
            clipBehavior: Clip.none,
            padding: axis == Axis.horizontal
                ? EdgeInsets.only(left: leadPad, right: trailPad)
                : EdgeInsets.only(top: leadPad, bottom: trailPad),
            itemBuilder: (context, index) =>
                _buildStripSlot(index, axis, thumbRadius),
          ),
        );
      },
    );
  }

  Widget _buildStripSlot(int index, Axis axis, double radius) {
    final file = _currentFiles[index];
    final isVideo = _isVideoFile(file);
    final isSelected = index == _currentIndex;
    final horizontal = axis == Axis.horizontal;
    final expandedHere = horizontal &&
        _videoExpanded &&
        isSelected &&
        isVideo &&
        _activeVideo != null;

    if (expandedHere) {
      final controller = _activeVideo!;
      final frames = _expandedFrameCount(controller.value.duration);
      String? source;
      if (file.localPath != null && File(file.localPath!).existsSync()) {
        source = file.localPath;
      } else {
        source = controller.dataSource;
      }
      return SizedBox(
        width: _slotWidth(index),
        child: Center(
          child: _ExpandedVideoStrip(
            key: ValueKey('expanded_${file.id}_$frames'),
            file: file,
            source: source,
            duration: controller.value.duration,
            frameCount: frames,
            tileWidth: _frameTileW,
            // Slightly taller than the regular thumbs — Samsung's expanded
            // film pops out of the row.
            height: _thumbH + 6,
            radius: radius,
            onScrubFraction: (fraction) {
              final d = controller.value.duration;
              if (d > Duration.zero) controller.seekTo(d * fraction);
            },
          ),
        ),
      );
    }

    // Photos 3:4, videos 4:3 — same height, videos wider.
    final double thumbW = horizontal ? (isVideo ? 53 : 30) : 27;
    final double thumbH = horizontal ? _thumbH : 36;
    // The centered item pops via scale so slot widths stay stable for the
    // offset math.
    final scale = isSelected ? 1.12 : 1.0;
    // Unexpanded playhead: rides over the current video's small thumb while
    // it plays, taller than the thumb (extends above and below).
    final showInlinePlayhead =
        horizontal && isVideo && isSelected && _activeVideo != null;

    return SizedBox(
      width: horizontal ? _slotWidth(index) : null,
      height: horizontal ? null : _vSlot,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (!isSelected) {
            _pageController.jumpToPage(index);
            return;
          }
          if (isVideo) _expandCurrentVideo();
        },
        child: Center(
          child: AnimatedScale(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            scale: scale,
            child: SizedBox(
              width: thumbW,
              height: thumbH,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(radius),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _FilmstripItem(
                            key: ValueKey(file.id),
                            file: file,
                          ),
                          if (isVideo)
                            Positioned(
                              right: 2,
                              bottom: 2,
                              child: Container(
                                width: 13,
                                height: 13,
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.5),
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: Icon(
                                    themeIconData('play', selected: true),
                                    size: 9,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (showInlinePlayhead)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ValueListenableBuilder<VideoPlayerValue>(
                          valueListenable: _activeVideo!,
                          builder: (_, value, _) {
                            final total = value.duration.inMilliseconds;
                            final fraction = total == 0
                                ? 0.0
                                : (value.position.inMilliseconds / total)
                                    .clamp(0.0, 1.0);
                            return Align(
                              alignment: Alignment(fraction * 2 - 1, 0),
                              child: OverflowBox(
                                maxHeight: thumbH + 10,
                                child: Container(
                                  width: 2.5,
                                  height: thumbH + 8,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButtons({
    required Color overlayColor,
    required bool vertical,
  }) {
    final fav = _currentFiles[_currentIndex].isFavorite;
    // Samsung Gallery's order: favorite, edit, info, share, delete.
    final children = <Widget>[
      IconButton(
        icon: Icon(
          fav
              ? themeIconData('heart', selected: true)
              : themeIconData('heart'),
        ),
        onPressed: _toggleFavorite,
        color: fav ? Colors.redAccent : overlayColor,
      ),
      // Edit — hidden for videos to keep the row balanced.
      if (!_currentIsVideo)
        IconButton(
          icon: ThemeIcon('pencilSimple'),
          onPressed: _openEditor,
          color: overlayColor,
        ),
      IconButton(
        icon: ThemeIcon('info'),
        onPressed: _showDetailsSheet,
        color: overlayColor,
      ),
      IconButton(
        icon: ThemeIcon('shareFat'),
        onPressed: () =>
            ShareDialog.show(context, _currentFiles[_currentIndex]),
        color: overlayColor,
      ),
      // Copy/Print/Wallpaper live in the AppBar's overflow menu — one
      // overflow surface, not two. Rename lives in the info sheet's Edit
      // button for the same reason.
      IconButton(
        icon: ThemeIcon('trash'),
        onPressed: _handleDelete,
        color: Colors.redAccent,
      ),
    ];
    if (vertical) {
      return Column(mainAxisSize: MainAxisSize.min, children: children);
    }
    return Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: children);
  }
}

enum _SaveMode { copy, replace }

class _SaveOptionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback? onTap;
  const _SaveOptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.enabled = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outline),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: enabled ? cs.primary : cs.onSurface.withAlpha(80),
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: enabled
                          ? cs.onSurface
                          : cs.onSurface.withAlpha(110),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: cs.onSurface.withAlpha(140),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Samsung Gallery-style info sheet:
///
///   Header line   — captured date/time in bold + `Edit` (placeholder)
///   Filename
///   Path (`/Internal storage/DCIM/Camera` — collapsed for readability)
///
///   Device model (bold)
///   Row 1        — size · dimensions · megapixels/resolution-tier
///   Row 2        — camera settings (photos) OR container info (videos)
///
///   Vault ID (small, muted — CipherNest extra, not on Samsung)
///
/// Every metadata field renders `null`-safe: missing EXIF just collapses
/// that row instead of showing "unknown". Loads asynchronously so the
/// sheet paints instantly and the rich rows fade in as extraction finishes.
class _InfoSheetBody extends StatefulWidget {
  final CnestFile file;
  final ScrollController scrollController;
  final VoidCallback onEdit;
  const _InfoSheetBody({
    required this.file,
    required this.scrollController,
    required this.onEdit,
  });

  @override
  State<_InfoSheetBody> createState() => _InfoSheetBodyState();
}

class _InfoSheetBodyState extends State<_InfoSheetBody> {
  FileMetadata? _meta;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final meta = await FileMetadataService().extract(widget.file);
    if (mounted) setState(() => _meta = meta);
  }

  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  static const _weekdays = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday',
    'Friday', 'Saturday', 'Sunday',
  ];

  String _fmtHeader(DateTime dt) {
    final wd = _weekdays[dt.weekday - 1];
    final month = _months[dt.month - 1];
    final hour12 = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final ampm = dt.hour < 12 ? 'am' : 'pm';
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$wd, ${dt.day} $month ${dt.year} · $hour12:$mm $ampm';
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  String _fmtDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// Samsung's "0.0ev" style — always signed, one decimal.
  String _fmtExposureBias(double v) {
    final sign = v >= 0 ? '' : '';
    return '$sign${v.toStringAsFixed(1)}ev';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final file = widget.file;
    final meta = _meta;
    // Fall back to the CnestFile's raw fields while metadata loads so the
    // header/filename never flash empty.
    final captured = meta?.captured ?? file.createdAt;

    // Row 1 — universal facts. Photos: size · WxH · megapixels.
    // Videos: size · WxH · resolution tier.
    final row1 = <String>[
      _fmtSize(file.sizeBytes),
      if (meta?.width != null && meta?.height != null)
        '${meta!.width}x${meta.height}',
      if (meta?.isVideo == true && meta?.resolutionTier != null)
        meta!.resolutionTier!
      else if (meta?.megapixels != null)
        '${meta!.megapixels}MP',
    ];

    // Row 2 — Samsung splits this line by media type:
    //   Video: duration · videoCodec · audioCodec · fps
    //   Photo: ISO · focal · exposure bias · aperture · shutter speed
    // The video row shows only what the MP4 parser could pull; missing
    // fields collapse gracefully (e.g. cloud-only video → just duration).
    final row2 = <String>[
      if (meta?.isVideo == true) ...[
        if (meta?.duration != null) _fmtDuration(meta!.duration!),
        if (meta?.videoCodec != null) meta!.videoCodec!,
        if (meta?.audioCodec != null) meta!.audioCodec!,
        if (meta?.fps != null) '${meta!.fps}fps',
      ] else ...[
        if (meta?.iso != null) 'ISO ${meta!.iso}',
        if (meta?.focalLengthMm != null)
          '${meta!.focalLengthMm!.round()}mm',
        if (meta?.exposureBias != null)
          _fmtExposureBias(meta!.exposureBias!),
        if (meta?.aperture != null) 'F${meta!.aperture!.toStringAsFixed(1)}',
        if (meta?.shutterSpeed != null) meta!.shutterSpeed!,
      ],
    ];

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        Center(
          child: Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(
              color: cs.onSurface.withAlpha(60),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        // Header row: date · time (bold) + Edit
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                _fmtHeader(captured),
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            // Rename + change captured date/time. Same button on Samsung's
            // info page; we route it through the viewer so the AppBar
            // title updates in place after a rename.
            TextButton(
              onPressed: widget.onEdit,
              style: TextButton.styleFrom(
                foregroundColor: cs.primary,
                padding: EdgeInsets.zero,
                minimumSize: const Size(48, 24),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Edit',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          file.filename,
          style: TextStyle(
            color: cs.onSurface.withAlpha(170),
            fontSize: 14,
          ),
        ),
        if (meta?.path != null) ...[
          const SizedBox(height: 2),
          Text(
            meta!.path!,
            style: TextStyle(
              color: cs.onSurface.withAlpha(140),
              fontSize: 14,
            ),
          ),
        ],
        const SizedBox(height: 24),
        if (meta?.deviceModel != null && meta!.deviceModel!.isNotEmpty)
          Text(
            meta.deviceModel!,
            style: TextStyle(
              color: cs.onSurface,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
        if (row1.isNotEmpty) ...[
          const SizedBox(height: 8),
          _InfoLine(items: row1, color: cs.onSurface.withAlpha(170)),
        ],
        if (row2.isNotEmpty) ...[
          const SizedBox(height: 4),
          _InfoLine(items: row2, color: cs.onSurface.withAlpha(170)),
        ],
        const SizedBox(height: 24),
        _AddTagChip(),
        const SizedBox(height: 32),
        // CipherNest-specific extras — grouped so they read as "vault
        // metadata" separate from the camera info block above.
        Text(
          'Vault',
          style: TextStyle(
            color: cs.onSurface.withAlpha(140),
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 6),
        SelectableText(
          file.id,
          style: TextStyle(
            color: cs.onSurface.withAlpha(140),
            fontSize: 11,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}

/// Samsung uses a thin vertical divider between fields on the info line.
/// We reproduce it with a low-opacity `|` character so we don't have to
/// build a custom Wrap-with-dividers layout.
class _InfoLine extends StatelessWidget {
  final List<String> items;
  final Color color;
  const _InfoLine({required this.items, required this.color});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final buf = StringBuffer(items.first);
    for (var i = 1; i < items.length; i++) {
      buf.write('  |  ');
      buf.write(items[i]);
    }
    return Text(
      buf.toString(),
      style: TextStyle(color: color, fontSize: 14, height: 1.4),
    );
  }
}

/// Return value of the Edit Info dialog. Same shape whether the user
/// changed one field, both, or neither — the caller diffs against the
/// original and only writes what actually moved.
class _EditInfoResult {
  final String filename;
  final DateTime captured;
  const _EditInfoResult({required this.filename, required this.captured});
}

/// Rename + change captured date/time. Two fields, one Save button. The
/// EXIF DateTimeOriginal inside the encrypted blob is deliberately NOT
/// modified — that would require re-encrypting the whole file. The vault
/// entry wins in-app; EXIF wins on export.
class _EditInfoDialog extends StatefulWidget {
  final CnestFile file;
  const _EditInfoDialog({required this.file});
  @override
  State<_EditInfoDialog> createState() => _EditInfoDialogState();
}

class _EditInfoDialogState extends State<_EditInfoDialog> {
  late final TextEditingController _nameCtrl;
  late DateTime _captured;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.file.filename);
    _captured = widget.file.createdAt;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _captured,
      firstDate: DateTime(1970),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null) return;
    if (!mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_captured),
    );
    if (time == null) return;
    setState(() {
      _captured = DateTime(
        date.year, date.month, date.day, time.hour, time.minute,
      );
    });
  }

  String _fmtDateTime(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hour12 =
        dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final ampm = dt.hour < 12 ? 'am' : 'pm';
    final mm = dt.minute.toString().padLeft(2, '0');
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}, $hour12:$mm $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Edit info'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _nameCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          InkWell(
            onTap: _pickDate,
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Captured',
                border: OutlineInputBorder(),
              ),
              child: Text(
                _fmtDateTime(_captured),
                style: TextStyle(color: cs.onSurface, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(
              context,
              _EditInfoResult(filename: name, captured: _captured),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Placeholder chip matching Samsung's `# Add tag` control. Wired to a
/// no-op for launch; tag storage is a v1.0.1 candidate.
class _AddTagChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: cs.onSurface.withAlpha(80)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '#',
              style: TextStyle(color: cs.onSurface.withAlpha(160), fontSize: 14),
            ),
            const SizedBox(width: 6),
            Text(
              'Add tag',
              style: TextStyle(color: cs.onSurface.withAlpha(160), fontSize: 14),
            ),
          ],
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
  final ValueChanged<bool> onZoomChanged;

  /// Reports this page's video controller + init handler to the screen so
  /// the dock (pill / mute / scrubber) can drive playback. (index, null,
  /// null) = this page's video is gone.
  final void Function(
    int index,
    VideoPlayerController? controller,
    Future<void> Function()? initHandler,
  ) onVideoBinding;

  const _SinglePhotoView({
    super.key,
    required this.file,
    required this.index,
    required this.onLoaded,
    required this.isFocused,
    required this.onZoomChanged,
    required this.onVideoBinding,
  });

  @override
  State<_SinglePhotoView> createState() => _SinglePhotoViewState();
}

class _SinglePhotoViewState extends State<_SinglePhotoView>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  Uint8List? _fullImage;
  Uint8List? _thumbImage;
  // Rung 1 placeholder bytes — MediaStore thumbnail.
  Uint8List? _assetThumbBytes;
  bool _isLoadingFull = true;
  // Nothing local, nothing cached, nothing in the cloud — a phantom entry
  // (e.g. interrupted auto-sync upload whose gallery copy was later
  // deleted). Renders a broken-image state instead of spinning forever.
  bool _loadFailed = false;
  bool _isVideo = false;

  // Video Player State
  VideoPlayerController? _videoController;
  bool _isPlayingVideo = false;
  bool _isBufferingVideo = false;
  // Mid-playback rebuffering (a chunk arrived late). ExoPlayer just freezes
  // the frame; without this flag a slow chunk reads as "paused".
  bool _isVideoStalled = false;

  // One shared zoom surface for placeholder + full image, so the transform
  // survives the cross-fade and the parent can watch the zoom level.
  final TransformationController _zoomCtrl = TransformationController();
  bool _lastReportedZoom = false;

  // Double-tap zoom animation (Samsung: 2.5x centered on the tap point).
  late final AnimationController _zoomAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<Matrix4>? _zoomTween;
  TapDownDetails? _doubleTapDetails;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _zoomAnim.addListener(_applyZoomAnim);
    _checkFileType();
    if (_isVideo && widget.isFocused) {
      // Hand the dock a way to start playback before any controller exists,
      // then autoplay muted — Samsung behavior on landing on a video.
      widget.onVideoBinding(widget.index, null, _initializeVideo);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.isFocused) unawaited(_initializeVideo());
      });
    }
    _loadImages();
  }

  /// Reported only when a gesture/animation ENDS — reporting live from a
  /// TransformationController listener rebuilt PageView/Dismissible
  /// mid-pinch, which cancelled the scale gesture (the "zoom is dead" bug).
  void _reportZoom() {
    final zoomed = _zoomCtrl.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _lastReportedZoom) return;
    _lastReportedZoom = zoomed;
    widget.onZoomChanged(zoomed);
  }

  void _applyZoomAnim() {
    final tween = _zoomTween;
    if (tween == null) return;
    _zoomCtrl.value = tween.value;
    if (_zoomAnim.isCompleted) _reportZoom();
  }

  void _animateZoomTo(Matrix4 target) {
    _zoomTween = Matrix4Tween(begin: _zoomCtrl.value, end: target).animate(
      CurvedAnimation(parent: _zoomAnim, curve: Curves.easeOutCubic),
    );
    _zoomAnim.forward(from: 0);
  }

  void _handleDoubleTap() {
    if (_isVideo) return;
    if (_zoomCtrl.value.getMaxScaleOnAxis() > 1.01) {
      _animateZoomTo(Matrix4.identity());
      return;
    }
    final pos = _doubleTapDetails?.localPosition;
    if (pos == null) return;
    const scale = 2.5;
    // Keeps the tapped point stationary: x' = s·x − p·(s−1) equals p at x=p.
    final target = Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(0, 3, -pos.dx * (scale - 1))
      ..setEntry(1, 3, -pos.dy * (scale - 1));
    _animateZoomTo(target);
  }

  /// Reads a previously persisted video frame from the shared thumb cache.
  Future<Uint8List?> _cachedVideoFrame() async {
    if (widget.file.cloudId == null) return null;
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/thumb_${widget.file.cloudId}.jpg');
    if (!await f.exists()) return null;
    try {
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Fire-and-forget: shares an obtained video frame with the filmstrip,
  /// grid, and future viewer opens via the standard thumb-cache path.
  void _persistVideoFrame(Uint8List bytes) {
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

  @override
  void didUpdateWidget(_SinglePhotoView oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Lost focus (user swiped away): pause the video, reset zoom, and
    // release the dock binding so the new page can claim it.
    if (oldWidget.isFocused && !widget.isFocused) {
      _videoController?.pause();
      _zoomCtrl.value = Matrix4.identity();
      _reportZoom();
      if (_isVideo) widget.onVideoBinding(widget.index, null, null);
    }
    // Gained focus: (re)bind this page's video to the dock and resume the
    // muted autoplay (a fresh init or a paused controller's play()).
    if (!oldWidget.isFocused && widget.isFocused && _isVideo) {
      widget.onVideoBinding(widget.index, _videoController, _initializeVideo);
      if (_videoController == null) {
        unawaited(_initializeVideo());
      } else {
        _videoController!.play();
      }
    }
  }

  // CRITICAL: Cleanup player when swiping away to free memory
  @override
  void dispose() {
    _zoomAnim.dispose();
    _zoomCtrl.dispose();
    _disposeVideoPlayer();
    super.dispose();
  }

  void _onVideoControllerValue() {
    final value = _videoController?.value;
    if (value == null) return;
    final stalled = value.isBuffering;
    if (stalled != _isVideoStalled && mounted) {
      setState(() => _isVideoStalled = stalled);
    }
  }

  void _disposeVideoPlayer() {
    if (_isVideo) widget.onVideoBinding(widget.index, null, null);
    _videoController?.removeListener(_onVideoControllerValue);
    _videoController?.dispose();
    _videoController = null;
    _isPlayingVideo = false;
    _isVideoStalled = false;
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

    // STEP 1 — placeholder, ALWAYS. Try the same three rungs the grid uses so
    // the viewer's first frame matches the cell the user just tapped instead
    // of black-flashing into a spinner.
    await _loadPlaceholder();

    // STEP 2 — full image. Local original wins; else cloud download.
    if (widget.file.localPath != null) {
      final localFile = File(widget.file.localPath!);
      if (await localFile.exists()) {
        if (_isVideo) {
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

    final cacheDir = await getTemporaryDirectory();

    if (_isVideo) {
      if (mounted) {
        setState(() => _isLoadingFull = false);
        widget.onLoaded(widget.index);
      }
      return;
    }

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

    if (widget.file.cloudId == null) {
      // Phantom entry — no local copy (checked above), nothing cached, and
      // the upload never completed. Nothing exists to show; ending the
      // spinner here is what prevents the infinite loader.
      if (mounted) {
        setState(() {
          _isLoadingFull = false;
          _loadFailed = true;
        });
      }
      return;
    }

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
      if (mounted) {
        setState(() {
          _isLoadingFull = false;
          _loadFailed = true;
        });
      }
    }
  }

  /// Three-rung placeholder. Whichever rung produces bytes first wins and the
  /// rest are skipped. Rung 2 (local original) doesn't set state — build()
  /// renders it directly via Image.file when localPath exists.
  Future<void> _loadPlaceholder() async {
    // RUNG 0 (videos only) — the shared disk thumb cache. MediaStore
    // regenerates video thumbs lazily (slow) and frame extraction is slower
    // still; whichever produced a frame before persisted it here, making
    // every later open instant.
    if (_isVideo) {
      final cached = await _cachedVideoFrame();
      if (cached != null) {
        if (mounted) setState(() => _assetThumbBytes = cached);
        return;
      }
    }

    // RUNG 1 — Android's MediaStore via photo_manager.
    if (widget.file.assetId != null) {
      try {
        final asset = await AssetEntity.fromId(widget.file.assetId!);
        if (asset != null) {
          final bytes = await asset.thumbnailDataWithSize(
            const ThumbnailSize(300, 300),
          );
          if (bytes != null) {
            if (_isVideo) _persistVideoFrame(bytes);
            if (mounted) setState(() => _assetThumbBytes = bytes);
            return;
          }
        }
      } catch (_) {
        // fall through
      }
    }

    // RUNG 2 — local original. Images: no state to set; build() renders the
    // file directly. Videos: the raw file is NOT decodable as an image
    // ("Invalid image data") — extract a real frame from it instead.
    if (widget.file.localPath != null &&
        File(widget.file.localPath!).existsSync()) {
      if (!_isVideo) return;
      try {
        final bytes = await VideoThumbnail.thumbnailData(
          video: widget.file.localPath!,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 300,
          quality: 60,
        );
        if (bytes != null) {
          _persistVideoFrame(bytes);
          if (mounted) setState(() => _assetThumbBytes = bytes);
          return;
        }
      } catch (_) {
        // Frame extraction failed — fall through to the cloud thumb.
      }
    }

    // RUNG 3 — decrypted thumb on disk (or fetch + decrypt now).
    if (widget.file.cloudId == null) return;
    final cacheDir = await getTemporaryDirectory();
    final thumbFile = File('${cacheDir.path}/thumb_${widget.file.cloudId}.jpg');
    if (await thumbFile.exists()) {
      if (mounted) setState(() => _thumbImage = thumbFile.readAsBytesSync());
      return;
    }
    // Fire-and-forget — when it arrives, build() picks it up.
    _downloadThumbnail(thumbFile);
  }

  // --- VIDEO PLAYER INITIALIZATION ---
  // Raw video_player, no Chewie: all controls live in the viewer's own dock
  // (pill + mute + in-strip scrubber) so photo and video chrome behave as
  // one unit.
  Future<void> _initializeVideo() async {
    if (_isBufferingVideo || _videoController != null) return;
    setState(() => _isBufferingVideo = true);

    try {
      // LOCAL-FIRST: if the original is on device, play it directly.
      // Zero network, zero decryption.
      VideoPlayerController? controller;
      if (widget.file.localPath != null) {
        final localFile = File(widget.file.localPath!);
        if (await localFile.exists()) {
          controller = VideoPlayerController.file(localFile);
        }
      }

      // CLOUD STREAMING: spin up local proxy server, point player at it.
      // Player issues HTTP range requests; server fetches encrypted chunks
      // on demand, decrypts only what's needed, returns plaintext slices.
      if (controller == null) {
        if (widget.file.cloudId == null) throw Exception('No cloud ID');
        final url = await VideoStreamingServer().beginSession(widget.file);
        if (!mounted) return;
        controller = VideoPlayerController.networkUrl(Uri.parse(url));
      }

      _videoController = controller;
      controller.addListener(_onVideoControllerValue);
      await controller.initialize();
      if (!mounted) return;

      setState(() {
        _isPlayingVideo = true;
        _isBufferingVideo = false;
      });
      if (widget.isFocused) {
        widget.onVideoBinding(widget.index, controller, _initializeVideo);
      }
      // Start silent — the parent binding applies the real mute state a
      // frame later, and every landing is muted-by-default anyway.
      await controller.setVolume(0);
      await controller.play();
    } catch (e) {
      // Common failure modes:
      //   PlatformException(VideoError) — codec/container mismatch. Look at
      //     the underlying container extension.
      //   SocketException / TimeoutException — cloud provider not reachable.
      //   StateError('No cloud ID') — file never finished uploading.
      // Full detail goes to debugPrint; user sees a friendlier line.
      debugPrint('Video initialize failed: $e');
      _videoController?.removeListener(_onVideoControllerValue);
      _videoController?.dispose();
      _videoController = null;
      if (mounted) {
        setState(() => _isBufferingVideo = false);
        final short = e.toString().length > 100
            ? '${e.toString().substring(0, 100)}…'
            : e.toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Couldn't play this video: $short"),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    // VIDEO PLAYER MODE — bare VideoPlayer; every control (play/pause,
    // time, mute, scrubber) lives in the viewer's dock, so a tap on the
    // video toggles ALL chrome as one unit, Samsung-style.
    if (_isPlayingVideo &&
        _videoController != null &&
        _videoController!.value.isInitialized) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: _videoController!.value.aspectRatio,
              child: VideoPlayer(_videoController!),
            ),
          ),
          // Rebuffering overlay — the slow-chunk wait must read as
          // "loading", never as a silent pause on a frozen frame.
          if (_isVideoStalled)
            const IgnorePointer(
              child: Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
        ],
      );
    }

    // IMAGE / THUMBNAIL MODE
    final localFile = widget.file.localPath != null
        ? File(widget.file.localPath!)
        : null;
    final hasLocal = localFile != null && localFile.existsSync();

    return Stack(
      fit: StackFit.expand,
      children: [
        // A+B. One zoom surface for placeholder AND full image — separate
        // InteractiveViewers would each carry their own transform, so the
        // zoom level could jump when the cross-fade swaps layers. Disabled
        // for videos: their placeholder isn't zoomable.
        // Zoom is reported on interaction END (not live): a mid-pinch parent
        // rebuild cancels the scale gesture. Double-tap = Samsung 2.5x.
        GestureDetector(
          onDoubleTapDown:
              _isVideo ? null : (details) => _doubleTapDetails = details,
          onDoubleTap: _isVideo ? null : _handleDoubleTap,
          child: InteractiveViewer(
            transformationController: _zoomCtrl,
            panEnabled: !_isVideo,
            scaleEnabled: !_isVideo,
            minScale: 1.0,
            maxScale: 4.0,
            onInteractionEnd: (_) => _reportZoom(),
            child: Stack(
            fit: StackFit.expand,
            children: [
              // Placeholder — first rung that's ready wins. Local originals
              // are only decodable for images; a video's rung-2 frame is
              // extracted in _loadPlaceholder and arrives as _assetThumbBytes.
              if (_assetThumbBytes != null)
                Image.memory(
                  _assetThumbBytes!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                )
              else if (hasLocal && !_isVideo)
                // Stays in the tree even after _fullImage arrives — removing
                // it while the full JPEG was still decoding was the black
                // flicker on local-gallery photos.
                Image.file(
                  localFile,
                  fit: BoxFit.contain,
                  cacheWidth: 300,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                )
              else if (_thumbImage != null)
                Image.memory(
                  _thumbImage!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),

              // Full image — fades in over the placeholder only once its
              // first frame is actually DECODED. Fading on "bytes arrived"
              // (the old _fullOpacity flip) ran the animation while the
              // JPEG was still decoding — nothing to paint yet.
              if (!_isVideo && _fullImage != null)
                Image.memory(
                  _fullImage!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  frameBuilder: (context, child, frame, wasSync) {
                    if (wasSync) return child;
                    return AnimatedOpacity(
                      opacity: frame == null ? 0.0 : 1.0,
                      duration: ThemeController().tokens.dur,
                      curve: ThemeController().tokens.easeOut,
                      child: child,
                    );
                  },
                ),
            ],
            ),
          ),
        ),

        // (The old giant center play button is gone — playback starts from
        // the dock's pill, same as Samsung Gallery.)

        // D. Spinner (For Image or Video Buffering)
        if ((!_isVideo && _isLoadingFull && _fullImage == null) ||
            _isBufferingVideo)
          const Center(child: CircularProgressIndicator(color: Colors.white)),

        // E. Broken state — nothing local, nothing cached, nothing in the
        // cloud (or the download failed). Matches the grid's broken tile.
        if (!_isVideo &&
            _loadFailed &&
            _fullImage == null &&
            _assetThumbBytes == null &&
            _thumbImage == null &&
            !hasLocal)
          Center(
            child: Icon(
              themeIconData('imageBroken'),
              color: Colors.white38,
              size: 64,
            ),
          ),
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
  Uint8List? _assetThumbBytes;
  String? _diskThumbPath;

  // Thumbnail cloud-IDs currently being fetched, across all strip items —
  // fast strip scrolling must not download the same thumb twice.
  static final Set<String> _inflightThumbs = {};

  bool get _isVideo {
    final ext = widget.file.filename.split('.').last.toLowerCase();
    return const {'mp4', 'mov', 'avi', 'mkv'}.contains(ext);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Rung 0 (videos only) — the shared disk thumb cache, where the viewer,
    // prewarm pass, or an earlier strip build persisted a frame. MediaStore
    // video thumbs materialize lazily, which is why video cells used to lag
    // behind photo cells here.
    if (_isVideo && widget.file.cloudId != null) {
      final cacheDir = await getTemporaryDirectory();
      final cached = File('${cacheDir.path}/thumb_${widget.file.cloudId}.jpg');
      if (await cached.exists()) {
        if (mounted) setState(() => _diskThumbPath = cached.path);
        return;
      }
    }

    // Rung 1 — MediaStore.
    if (widget.file.assetId != null) {
      try {
        final asset = await AssetEntity.fromId(widget.file.assetId!);
        if (asset != null) {
          final bytes = await asset.thumbnailDataWithSize(
            const ThumbnailSize(120, 120),
          );
          if (bytes != null) {
            if (mounted) setState(() => _assetThumbBytes = bytes);
            return;
          }
        }
      } catch (_) {}
    }

    // Rung 2 — local original. Images render via build() directly; videos
    // need a real frame extracted (raw video bytes aren't an image).
    if (widget.file.localPath != null &&
        File(widget.file.localPath!).existsSync()) {
      if (!_isVideo) {
        if (mounted) setState(() {});
        return;
      }
      try {
        final bytes = await VideoThumbnail.thumbnailData(
          video: widget.file.localPath!,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 300,
          quality: 60,
        );
        if (bytes != null) {
          _persistFrame(bytes);
          if (mounted) setState(() => _assetThumbBytes = bytes);
          return;
        }
      } catch (_) {
        // Fall through to the cloud thumb.
      }
    }

    // Rung 3 — cached decrypted thumb on disk, or fetch it now. Without the
    // fetch, cloud-only files beyond the viewer's ±2 prewarm window render
    // as permanent grey squares in the strip.
    if (widget.file.cloudId == null) return;
    final cacheDir = await getTemporaryDirectory();
    final f = File('${cacheDir.path}/thumb_${widget.file.cloudId}.jpg');
    if (await f.exists()) {
      if (mounted) setState(() => _diskThumbPath = f.path);
      return;
    }
    await _downloadThumb(f);
  }

  /// Fire-and-forget: extraction is expensive, so share the frame with the
  /// viewer/grid via the standard thumb-cache path. 300px so the cache entry
  /// is also good enough as the viewer's placeholder.
  void _persistFrame(Uint8List bytes) {
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

  Future<void> _downloadThumb(File target) async {
    final thumbId = widget.file.thumbnailCloudId;
    if (thumbId == null || _inflightThumbs.contains(thumbId)) return;
    _inflightThumbs.add(thumbId);
    try {
      final encrypted = await CloudService().downloadFile(thumbId);
      final decrypted = await EncryptionService.decryptFile(encrypted);
      await target.writeAsBytes(decrypted);
      if (mounted) setState(() => _diskThumbPath = target.path);
    } catch (_) {
      // Cell stays grey; a rebuild retries.
    } finally {
      _inflightThumbs.remove(thumbId);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget fallback(_, _, _) => Container(color: Colors.grey[800]);

    if (_assetThumbBytes != null) {
      return Image.memory(
        _assetThumbBytes!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: fallback,
      );
    }
    // Local originals are only decodable for images — a video's frame is
    // extracted in _load and arrives via _assetThumbBytes above.
    if (!_isVideo && widget.file.localPath != null) {
      final f = File(widget.file.localPath!);
      if (f.existsSync()) {
        return Image.file(
          f,
          fit: BoxFit.cover,
          cacheWidth: 120,
          gaplessPlayback: true,
          errorBuilder: fallback,
        );
      }
    }
    if (_diskThumbPath != null) {
      return Image.file(
        File(_diskThumbPath!),
        fit: BoxFit.cover,
        cacheWidth: 120,
        gaplessPlayback: true,
        errorBuilder: fallback,
      );
    }
    return Container(color: Colors.grey[800]);
  }
}

/// Samsung-style playback pill: play/pause glyph + "mm:ss / mm:ss". Without
/// a controller (video not started) it's just the play glyph — tapping it
/// asks the dock to initialize playback.
class _VideoPill extends StatelessWidget {
  final VideoPlayerController? controller;
  final bool vertical;
  final VoidCallback onPlayPause;
  const _VideoPill({
    required this.controller,
    required this.vertical,
    required this.onPlayPause,
  });

  static String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final Widget content = c == null
        ? ThemeIcon('play', selected: true, size: 20, color: Colors.white)
        : ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: c,
            builder: (_, value, _) {
              final icon = ThemeIcon(
                value.isPlaying ? 'pause' : 'play',
                selected: true,
                size: 20,
                color: Colors.white,
              );
              final position = Text(
                _fmt(value.position),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: vertical ? 10 : 13,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              );
              final total = Text(
                vertical ? _fmt(value.duration) : ' / ${_fmt(value.duration)}',
                style: TextStyle(
                  color: Colors.white60,
                  fontSize: vertical ? 9 : 13,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              );
              if (vertical) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [icon, const SizedBox(height: 2), position, total],
                );
              }
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [icon, const SizedBox(width: 8), position, total],
              );
            },
          );

    return GestureDetector(
      onTap: onPlayPause,
      child: Container(
        padding: vertical
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 10)
            : const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(999),
        ),
        child: content,
      ),
    );
  }
}

/// Round translucent icon button — mute toggle, frame capture (Samsung's
/// circular glass buttons flanking the playback pill).
class _GlassIconButton extends StatelessWidget {
  final String icon;
  final VoidCallback onTap;
  const _GlassIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          shape: BoxShape.circle,
        ),
        child: Center(
          child: ThemeIcon(
            icon,
            selected: true,
            size: 18,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// The expanded video segment inside the gallery bar: one tile per second
/// of video (capped at 12, spread evenly across the full duration),
/// extracted lazily and cached. Scrubbing happens by scrolling the bar under
/// the fixed center playhead; tapping a tile seeks straight to it.
class _ExpandedVideoStrip extends StatefulWidget {
  final CnestFile file;
  final String? source;
  final Duration duration;
  final int frameCount;
  final double tileWidth;
  final double height;
  final double radius;
  final ValueChanged<double> onScrubFraction;

  const _ExpandedVideoStrip({
    super.key,
    required this.file,
    required this.source,
    required this.duration,
    required this.frameCount,
    required this.tileWidth,
    required this.height,
    required this.radius,
    required this.onScrubFraction,
  });

  @override
  State<_ExpandedVideoStrip> createState() => _ExpandedVideoStripState();
}

class _ExpandedVideoStripState extends State<_ExpandedVideoStrip> {
  // Frames survive collapse/expand cycles and page swipes — extraction costs
  // one MediaMetadataRetriever pass per frame, so never pay twice.
  static final Map<String, List<Uint8List?>> _frameCache = {};
  static final Set<String> _extracting = {};

  String get _cacheKey => '${widget.file.id}#${widget.frameCount}';

  @override
  void initState() {
    super.initState();
    _ensureFrames();
  }

  Future<void> _ensureFrames() async {
    final key = _cacheKey;
    _frameCache.putIfAbsent(
      key,
      () => List<Uint8List?>.filled(widget.frameCount, null),
    );
    if (_extracting.contains(key)) return;
    final source = widget.source;
    if (source == null) return;
    final frames = _frameCache[key]!;
    if (!frames.contains(null)) return;
    _extracting.add(key);
    try {
      final totalMs = widget.duration.inMilliseconds;
      for (var i = 0; i < widget.frameCount; i++) {
        if (frames[i] != null) continue;
        try {
          final bytes = await VideoThumbnail.thumbnailData(
            video: source,
            imageFormat: ImageFormat.JPEG,
            timeMs: (totalMs * (i + 0.5) / widget.frameCount).round(),
            maxWidth: 120,
            quality: 50,
          );
          frames[i] = bytes;
        } catch (_) {
          // Tile stays dark; keep extracting the rest.
        }
        if (mounted) setState(() {});
      }
    } finally {
      _extracting.remove(key);
    }
  }

  @override
  Widget build(BuildContext context) {
    final frames = _frameCache[_cacheKey]!;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => widget.onScrubFraction(
        (d.localPosition.dx / (widget.frameCount * widget.tileWidth))
            .clamp(0.0, 1.0),
      ),
      child: SizedBox(
        width: widget.frameCount * widget.tileWidth,
        height: widget.height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.radius),
          child: Row(
            children: [
              for (var i = 0; i < widget.frameCount; i++)
                SizedBox(
                  width: widget.tileWidth,
                  height: widget.height,
                  child: frames[i] != null
                      ? Image.memory(
                          frames[i]!,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) =>
                              Container(color: Colors.grey[900]),
                        )
                      : Container(color: Colors.grey[900]),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
