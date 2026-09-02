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
import '../../../services/cache_manager_service.dart';
import '../../../services/local_content_guard.dart';
import '../../utils/byte_format.dart';
import '../../utils/perf_trace.dart';
import '../../../services/database_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/recycle_bin_service.dart';
import '../../../services/auto_sync_service.dart';
import '../../../services/file_metadata_service.dart';
import '../../../services/cnest_errors.dart';
import '../../../services/image_edit_service.dart';
import '../../../services/notify.dart';
import '../../../services/upload_pipeline.dart';
import '../../../services/video_streaming_server.dart';
import '../../widgets/file_actions.dart';
import '../../widgets/friendly_error_sheet.dart';
import '../share/share_dialog.dart';
import 'image_editor_screen.dart';
import 'photo_hero.dart';
import 'pictures_tab.dart' show GalleryGridItem;

class ImageViewerScreen extends StatefulWidget {
  final List<CnestFile> files;
  final int initialIndex;

  /// Drive-style single-file preview (launched from the Files browser):
  /// full-screen in place, back returns to the folder. No timeline chrome —
  /// no filmstrip, no scrubber, no position counter — and with the one-item
  /// [files] list the pager has nothing to swipe to. The swipe-through
  /// gallery experience stays exclusive to the Photos & Videos tab.
  final bool standalone;

  /// Recycle-bin mode: the delete button purges PERMANENTLY (with its own
  /// confirm), a Restore action appears, and every export/edit affordance
  /// (favourite, edit, share, save, wallpaper, print, copy, info-sheet
  /// rename) is hidden — a binned file is evidence, not a workspace.
  /// Swiping stays: the bin passes its own binned-only list.
  final bool fromRecycleBin;

  /// Live index reports so the launching gallery can keep the viewed
  /// photo's tile built and on-screen — the close hero needs a cell to
  /// land in even after swiping far from the opened photo.
  final ValueChanged<int>? onIndexChanged;

  const ImageViewerScreen({
    super.key,
    required this.files,
    required this.initialIndex,
    this.standalone = false,
    this.fromRecycleBin = false,
    this.onIndexChanged,
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

  // Swipe-down-to-close, driven by the same raw-pointer tracking as the
  // details sheet — NOT by a Dismissible. Dismissible's vertical drag
  // recognizer plus the PageView's horizontal one covered both axes of the
  // gesture arena, so whichever finger of a pinch moved first handed the
  // gesture to a drag before InteractiveViewer's scale recognizer could
  // claim it — pinch-to-zoom effectively never fired. Listeners see raw
  // events without entering the arena, so this path can't steal the pinch.
  bool _dismissDragging = false;
  double _dismissDy = 0;
  bool _dismissPopped = false;

  // True while ≥2 fingers are down. Freezes the pager so its horizontal
  // drag can't fight (or keep dragging under) the raw-pointer pinch in
  // _SinglePhotoView. Flipping it on pointer-down is safe: the pinch
  // hasn't produced any movement yet, and the raw engine doesn't care
  // about rebuilds.
  bool _multiTouch = false;

  // Set the moment a single-finger drag reads as VERTICAL (sheet or
  // dismiss). Freezes the pager for the rest of the gesture — without it
  // the pager's horizontal drag tracks the stray dx of a vertical swipe
  // and the page wobbles left/right under the sheet/dismiss motion.
  bool _verticalDragLock = false;

  // --- Active-video binding, reported by the focused page. The dock uses it
  // to render the Samsung-style pill (play/pause + time), the mute toggle,
  // and the in-strip scrubber.
  VideoPlayerController? _activeVideo;
  Future<void> Function()? _activeVideoInit;
  int? _activeVideoIndex;
  // Duration from file metadata, so the pill can show "00:00 / 00:23" while
  // the stream is still being fetched (never a naked play button).
  Duration? _videoDurationHint;
  // Samsung behavior: every video starts playing muted when you land on it.
  bool _videoMuted = true;
  // True only when the USER pressed pause. A buffer underrun also drops
  // isPlaying, so intent — not player state — is what decides whether a
  // stall shows the loader and auto-resumes, or stays politely paused.
  bool _videoPauseIntent = false;
  // Tapping the centered video thumb expands it into a per-second frame
  // strip; the bar then scrolls under a FIXED center playhead to scrub.
  // Collapses on tap, page change, or when the scrub exits the segment.
  bool _videoExpanded = false;
  // Scrub throttling state (see _handleStripScrollUpdate).
  DateTime _lastScrubSeek = DateTime.fromMillisecondsSinceEpoch(0);
  double? _pendingScrubFraction;
  bool _resumeAfterScrub = false;

  // --- Center-locked filmstrip geometry (Samsung) ---
  // Photos are 3:4, videos 4:3 (same height, wider), the expanded video is
  // one tile per second (capped). Slots have VARIABLE widths, so all offset
  // math walks slot widths instead of assuming a uniform extent.
  static const double _stripBarHeight = 56.0;
  static const double _thumbH = 40.0;
  static const double _photoSlot = 36.0; // 30 wide thumb + 6 margins
  static const double _videoSlot = 59.0; // 53 wide (4:3 of 40) + 6
  static const double _frameTileW = 44.0; // expanded per-second tile
  static const double _minFrameTileW = 16.0; // thinnest legible film sliver
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

  /// Samsung shows a dense film: ~1 tile per second for short clips, and for
  /// long ones as many tiles as fit the segment without a sliver dropping
  /// below [_minFrameTileW] — density is what makes the scrub read as silk.
  int _expandedFrameCount(Duration d) {
    final bySeconds = d.inSeconds.clamp(1, 30).toInt();
    // The strip may not have laid out yet when preloading frames — fall back
    // to the screen width so preload and expand agree on the count.
    final viewport =
        _stripViewport > 0 ? _stripViewport : MediaQuery.sizeOf(context).width;
    final byWidth = max(1, (viewport * 0.72) ~/ _minFrameTileW);
    return min(bySeconds, byWidth);
  }

  /// Expanded tile width shrinks so the whole segment never exceeds ~72% of
  /// the bar — otherwise a long video's 12 tiles cover the viewport and the
  /// neighbor thumbs vanish off-screen.
  double get _expandedTileWidth {
    final controller = _activeVideo;
    if (controller == null || _stripViewport <= 0) return _frameTileW;
    final frames = _expandedFrameCount(controller.value.duration);
    return min(_frameTileW, (_stripViewport * 0.72) / frames);
  }

  double _slotWidth(int index) {
    if (_stripAxis == Axis.vertical) return _vSlot;
    final f = _currentFiles[index];
    if (!_isVideoFile(f)) return _photoSlot;
    if (_videoExpanded && index == _currentIndex && _activeVideo != null) {
      return _expandedFrameCount(_activeVideo!.value.duration) *
              _expandedTileWidth +
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
    _loadVideoDurationHint();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToIndex(_currentIndex),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    _filmStripController.dispose();
    super.dispose();
  }

  void _loadVideoDurationHint() {
    _videoDurationHint = null;
    if (_currentFiles.isEmpty || !_currentIsVideo) return;
    final file = _currentFiles[_currentIndex];
    final expectIndex = _currentIndex;
    FileMetadataService().extract(file).then((meta) {
      if (!mounted || _currentIndex != expectIndex) return;
      if (meta.duration != null) {
        setState(() => _videoDurationHint = meta.duration);
      }
    });
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
    final segWidth = _expandedFrameCount(duration) * _expandedTileWidth;
    if (centerX < segStart - 12 || centerX > segStart + segWidth + 12) {
      // Scrubbed past the segment — collapse and let selection take over.
      setState(() => _videoExpanded = false);
      _pendingScrubFraction = null;
      if (_resumeAfterScrub) {
        _resumeAfterScrub = false;
        controller.play();
      }
      _syncMainPageFromStrip();
      return;
    }
    if (duration <= Duration.zero) return;
    final fraction = ((centerX - segStart) / segWidth).clamp(0.0, 1.0);
    // Scrub politely: pause playback, throttle seeks (ExoPlayer chokes on a
    // seek per scroll tick — playback looks frozen), and let ScrollEnd land
    // the final precise seek.
    if (controller.value.isPlaying) {
      controller.pause();
      _resumeAfterScrub = true;
    }
    _pendingScrubFraction = fraction;
    final now = DateTime.now();
    if (now.difference(_lastScrubSeek) >= const Duration(milliseconds: 180)) {
      _lastScrubSeek = now;
      controller.seekTo(duration * fraction);
    }
  }

  /// Called when an expanded-scrub drag/fling settles: issue the exact final
  /// seek and resume playback if we paused it for the scrub.
  void _finishScrub() {
    final controller = _activeVideo;
    final fraction = _pendingScrubFraction;
    _pendingScrubFraction = null;
    if (controller != null && fraction != null) {
      final duration = controller.value.duration;
      if (duration > Duration.zero) controller.seekTo(duration * fraction);
    }
    if (_resumeAfterScrub) {
      _resumeAfterScrub = false;
      controller?.play();
    }
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
        _expandedFrameCount(controller.value.duration) * _expandedTileWidth;
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
    _restoreStripPosition();
  }

  void _collapseCurrentVideo() {
    if (!_videoExpanded) return;
    setState(() => _videoExpanded = false);
    _restoreStripPosition();
  }

  /// Puts the strip back where it belongs after a rebuild that reset its
  /// scroll position (chrome hide/show, expansion): centered on the current
  /// item, or on the playback fraction while a video is expanded.
  void _restoreStripPosition() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_filmStripController.hasClients) return;
      if (_currentFiles.isEmpty) return;
      double target;
      final controller = _activeVideo;
      if (_videoExpanded && controller != null) {
        final duration = controller.value.duration;
        final fraction = duration.inMilliseconds == 0
            ? 0.0
            : (controller.value.position.inMilliseconds /
                    duration.inMilliseconds)
                .clamp(0.0, 1.0);
        target = _stripOffsetForVideoFraction(fraction);
      } else {
        target = _stripOffsetFor(_currentIndex);
      }
      _filmStripController.jumpTo(
        target.clamp(0.0, _filmStripController.position.maxScrollExtent),
      );
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

  Future<void> _downloadFileAtIndex(int index) =>
      trace('viewerPrefetch', () => _downloadFileAtIndexImpl(index));

  Future<void> _downloadFileAtIndexImpl(int index) async {
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
    // Local videos WITHOUT a MediaStore binding: pre-extract a frame into
    // the shared thumb cache while the user is still on a neighboring page —
    // extraction takes a few hundred ms, which is exactly the filmstrip lag
    // being hidden here. MediaStore-bound videos are excluded (same
    // assetId == null gate as _persistVideoFrame/_persistFrame): Android
    // serves their frame, and this write was the last remaining reason a
    // fully-local video still put bytes in the app cache.
    final ext = file.filename.split('.').last.toLowerCase();
    final isVideo = const {'mp4', 'mov', 'avi', 'mkv'}.contains(ext);
    if (isVideo &&
        file.assetId == null &&
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

  /// Removes the current file from the in-viewer list after a delete or
  /// restore, popping (result true) when nothing is left to show.
  void _removeCurrentFromList() {
    setState(() {
      _currentFiles.removeAt(_currentIndex);
      _hasDeleted = true;
      if (_currentFiles.isEmpty) {
        Navigator.pop(context, true);
      } else if (_currentIndex >= _currentFiles.length) {
        _currentIndex = _currentFiles.length - 1;
      }
    });
  }

  /// Bin mode: the file is ALREADY binned — recording another deleteFile
  /// would restart its 30-day clock and detach it from its folder's restore
  /// group (the op_replay re-stamp branch). The only delete offered here is
  /// the permanent one.
  Future<void> _handleDeleteForever() async {
    final file = _currentFiles[_currentIndex];
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete permanently?'),
        content: const Text(
          'This cannot be undone. The file is removed from your vault and '
          'your cloud everywhere.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Delete forever',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final ok = await RecycleBinService().purgeFilePermanently(file);
    if (!mounted) return;
    if (!ok) {
      // The row purge didn't land (db closed mid-purge, disk full) — the
      // file still exists, so it must not vanish from the pager or claim
      // success.
      Notify.error('Couldn\'t delete — please try again');
      return;
    }
    _removeCurrentFromList();
    if (_currentFiles.isNotEmpty) {
      Notify.info('Permanently deleted');
    }
  }

  /// Bin mode: un-deletes the current file (its folder cause, if any, is
  /// handled by replay) and drops it from the binned list.
  Future<void> _handleRestore() async {
    final file = _currentFiles[_currentIndex];
    await DatabaseService().restoreFile(file.id);
    if (!mounted) return;
    _removeCurrentFromList();
    if (_currentFiles.isNotEmpty) {
      Notify.info('Restored');
    }
  }

  // --- DELETE LOGIC ---
  // Soft-delete: the encrypted blob and decrypted cache stay put for 30 days
  // so restores are instant and offline. RecycleBinService.sweepRecycleBin
  // wipes them at TTL.
  Future<void> _handleDelete() async {
    if (widget.fromRecycleBin) return _handleDeleteForever();
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
            child: Text(
              'Delete',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await DatabaseService().deleteFile(fileToDelete.id);
      AutoSyncService.trackDeletion(fileToDelete.filename, fileToDelete.sizeBytes);
      DatabaseBackupService().scheduleBackup();

      _removeCurrentFromList();

      if (_currentFiles.isNotEmpty) {
        Notify.info('Moved to Recycle Bin');
      }
    } catch (e) {
      Notify.error('Delete failed: $e');
    }
  }

  /// Hide/unhide the current file from the specialized views. The viewer
  /// stays open (it is also the unhide surface); grids refresh via the DB
  /// notifier, and _hasDeleted is the pop-result belt for FutureBuilder
  /// callers.
  Future<void> _toggleHidden() async {
    if (_currentFiles.isEmpty) return;
    final file = _currentFiles[_currentIndex];
    final next = !file.isHidden;
    await DatabaseService().setFileHidden(file.id, next);
    if (!mounted) return;
    setState(() {
      _currentFiles[_currentIndex] = file.copyWith(isHidden: next);
      _hasDeleted = true;
    });
    Notify.info(next ? 'Hidden from views' : 'Visible in views again');
  }

  Future<void> _toggleFavorite() async {
    if (_currentFiles.isEmpty) return;
    final file = _currentFiles[_currentIndex];
    final next = !file.isFavorite;
    await DatabaseService().setFavorite(file.id, next);
    final updated = file.copyWith(isFavorite: next);
    setState(() => _currentFiles[_currentIndex] = updated);
    Notify.info(next ? 'Added to favorites' : 'Removed from favorites');
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
    // the changes without a pop-and-rebuild.
    final updated =
        file.copyWith(filename: result.filename, createdAt: result.captured);
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

    final loaded = await _currentImageBytes();
    if (loaded == null) {
      Notify.error('Could not load image to edit');
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
      Notify.info(
        mode == _SaveMode.replace ? 'Photo replaced' : 'Edited copy saved',
      );
    } catch (e) {
      if (mounted) Navigator.of(context).pop(); // dismiss progress
      // Typed sheet, never raw exception text (session-expired 401s were
      // reaching users verbatim here).
      final err = e is CnestError ? e : UploadPipeline.mapUploadError(e);
      if (mounted) await showCnestError(context, err);
    }
  }

  Future<_SaveMode?> _showSaveSheet(CnestFile source) async {
    final isCameraRoll = source.assetId != null;
    final isUnsyncedVaultFile =
        source.cloudId == null || !source.isUploaded;
    // We can only replace when the source is a vault file already in cloud
    // and isn't a camera-roll original we'd be overwriting in spirit.
    final canReplace = !isCameraRoll && !isUnsyncedVaultFile;

    // Surface + corner shape come from the theme's bottomSheetTheme.
    // Scroll-controlled + scrollable: ~347 px of content beats the default
    // 9/16 sheet cap on a 533 px screen and in landscape.
    return showModalBottomSheet<_SaveMode>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
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
                        color:
                            Theme.of(ctx).colorScheme.onSurface.withAlpha(60),
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
                    icon: 'copy',
                    title: 'Save as copy',
                    subtitle:
                        'Keep the original. Recommended: original stays intact.',
                    onTap: () => Navigator.pop(ctx, _SaveMode.copy),
                  ),
                  const SizedBox(height: 10),
                  _SaveOptionTile(
                    icon: 'arrowsClockwise',
                    title: 'Replace original',
                    subtitle: canReplace
                        ? 'Delete the original and keep only the edit.'
                        : isCameraRoll
                            ? 'Unavailable for camera-roll photos. We never '
                                'overwrite your gallery.'
                            : 'Unavailable. Original isn\'t synced to cloud yet.',
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
          ),
        );
      },
    );
  }

  void _showProcessingDialog() {
    // White-on-scrim is deliberate: the dialog floats on the modal barrier,
    // which is dark in both light and dark mode.
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
    final isImage = file.type == CnestFileType.image &&
        !['mp4', 'mov', 'avi', 'mkv']
            .contains(file.filename.split('.').last.toLowerCase());
    try {
      if (isImage) {
        final bytes = await _currentImageBytes();
        if (bytes == null) throw Exception('Could not load image');
        await Pasteboard.writeImage(bytes);
        Notify.info('Image copied to clipboard');
      } else {
        await Clipboard.setData(ClipboardData(text: file.filename));
        Notify.info('Filename copied to clipboard');
      }
    } catch (e) {
      Notify.error('Copy failed: $e');
    }
  }

  Future<void> _printCurrent() async {
    if (_currentFiles.isEmpty) return;
    // Video bytes can't be laid out as a PDF image — same "Invalid image
    // data" failure as the thumbnail path.
    if (_currentIsVideo) {
      Notify.error("Videos can't be printed");
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
      Notify.error('Print failed: $e');
    }
  }

  /// Set the current photo as Android wallpaper. Decrypts in-memory, writes to
  /// the app's private temp dir, hands the path to AsyncWallpaper, then wipes
  /// the temp file. The wallpaper manager is an in-app sink — no public-storage
  /// or share-intent leak of plaintext bytes.
  Future<void> _setAsWallpaper() async {
    if (_currentFiles.isEmpty) return;
    final file = _currentFiles[_currentIndex];

    final ext = file.filename.split('.').last.toLowerCase();
    if (const {'mp4', 'mov', 'avi', 'mkv'}.contains(ext)) {
      Notify.error("Videos can't be set as wallpaper");
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
      Notify.info('Wallpaper set');
    } catch (e) {
      Notify.error('Failed: $e');
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
    // Surface + corner shape come from the theme's bottomSheetTheme.
    // Scroll-controlled + scrollable: three tiles (~375 px) beat the
    // default 9/16 sheet cap on a 640 px screen.
    return showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
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
                        color:
                            Theme.of(ctx).colorScheme.onSurface.withAlpha(60),
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
                    icon: 'house',
                    title: 'Home screen',
                    subtitle: 'Apply only to the home screen.',
                    onTap: () =>
                        Navigator.pop(ctx, AsyncWallpaper.HOME_SCREEN),
                  ),
                  const SizedBox(height: 10),
                  _SaveOptionTile(
                    icon: 'lockKey',
                    title: 'Lock screen',
                    subtitle: 'Apply only to the lock screen.',
                    onTap: () =>
                        Navigator.pop(ctx, AsyncWallpaper.LOCK_SCREEN),
                  ),
                  const SizedBox(height: 10),
                  _SaveOptionTile(
                    icon: 'devices',
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
          ),
        );
      },
    );
  }

  /// A zoomed pan pulled past the photo's edge (Samsung edge handoff):
  /// turn the page. The pager animates programmatically, so the
  /// NeverScrollable physics that guard the zoom don't block it; the page
  /// change resets the zoom state through the normal onPageChanged path.
  void _handleEdgeOvershoot(int direction) {
    final target = _currentIndex + direction;
    if (target < 0 || target >= _currentFiles.length) return;
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  /// Finger lifted mid dismiss-drag: past the threshold → close the viewer;
  /// short of it → snap the photo back (the AnimatedSlide/Scale pair
  /// animates the return once _dismissDragging flips off).
  void _endDismissDrag() {
    if (_dismissDy > 120 && !_dismissPopped) {
      _dismissPopped = true;
      Navigator.pop(context, _hasDeleted);
      return;
    }
    setState(() {
      _dismissDragging = false;
      _dismissDy = 0;
    });
  }

  void _showDetailsSheet() {
    final file = _currentFiles[_currentIndex];
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // Samsung's info sheet sits on the base background, not the raised
      // sheet surface; the corner shape still comes from bottomSheetTheme.
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.3,
        maxChildSize: 0.85,
        expand: false,
        builder: (_, controller) => _InfoSheetBody(
          file: file,
          scrollController: controller,
          canEdit: !widget.fromRecycleBin,
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
    // Viewer chrome floats over the theme background (Samsung: white chrome
    // on black in dark mode, dark chrome on white in light mode).
    final overlayColor = theme.colorScheme.onSurface;

    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: _showControls
            ? AppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                iconTheme: IconThemeData(color: overlayColor),
                title: Column(
                  children: [
                    Text(
                      _currentFiles[_currentIndex].filename,
                      // Two lines + counter still fit the 56 px toolbar.
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, color: overlayColor),
                    ),
                    if (!widget.standalone)
                      Text(
                        '${_currentIndex + 1} / ${_currentFiles.length}',
                        style: TextStyle(
                          fontSize: 10,
                          color: overlayColor.withValues(alpha: 0.7),
                        ),
                      ),
                  ],
                ),
                leading: IconButton(
                  icon: ThemeIcon('arrowLeft'),
                  onPressed: () => Navigator.pop(context, _hasDeleted),
                ),
                actions: [
                  // Export affordances are wrong for a binned file — bin
                  // mode keeps the bar to Restore / Info / Delete forever.
                  if (!widget.fromRecycleBin) ...[
                    IconButton(
                      icon: ThemeIcon('arrowsCounterClockwise'),
                      onPressed: () {},
                    ),
                    PopupMenuButton<String>(
                      icon:
                          ThemeIcon('dotsThreeVertical', color: overlayColor),
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'save',
                          child: Text('Save to device'),
                        ),
                        const PopupMenuItem(
                          value: 'copy',
                          child: Text('Copy to clipboard'),
                        ),
                        const PopupMenuItem(
                          value: 'wall',
                          child: Text('Set as wallpaper'),
                        ),
                        const PopupMenuItem(
                            value: 'print', child: Text('Print')),
                        PopupMenuItem(
                          value: 'hide',
                          child: Text(
                              _currentFiles[_currentIndex].isHidden
                                  ? 'Unhide'
                                  : 'Hide from views'),
                        ),
                      ],
                      onSelected: (val) {
                        switch (val) {
                          case 'save':
                            saveFileToDevice(
                                context, _currentFiles[_currentIndex]);
                            break;
                          case 'copy':
                            _copyToClipboard();
                            break;
                          case 'wall':
                            _setAsWallpaper();
                            break;
                          case 'print':
                            _printCurrent();
                            break;
                          case 'hide':
                            _toggleHidden();
                            break;
                        }
                      },
                    ),
                  ],
                ],
              )
            : null,

        body: OrientationBuilder(
          builder: (context, orientation) {
            final isLandscape = orientation == Orientation.landscape;
            // In landscape the controls live in a vertical rail on the right
            // (80 px plus any right-mounted nav bar, which the rail absorbs).
            // Shrink the photo area so it never sits behind the rail.
            final photoRightPadding = isLandscape && _showControls
                ? 80.0 + MediaQuery.paddingOf(context).right
                : 0.0;
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
                      // Multi-touch means pinch — never the details sheet,
                      // any in-progress dismiss drag snaps back, and the
                      // pager freezes for the rest of the gesture.
                      if (_activePointers > 1) {
                        _sheetTriggered = true;
                        if (!_multiTouch || _dismissDragging) {
                          setState(() {
                            _multiTouch = true;
                            _dismissDragging = false;
                            _dismissDy = 0;
                          });
                        }
                      }
                    },
                    onPointerMove: (event) {
                      if (_sheetTriggered || _isZoomed || _activePointers != 1) {
                        return;
                      }
                      _dragDx += event.delta.dx;
                      _dragDy += event.delta.dy;
                      if (_dismissDragging) {
                        final dy = _dismissDy + event.delta.dy;
                        setState(() => _dismissDy = dy < 0 ? 0 : dy);
                        return;
                      }
                      // Commit to VERTICAL early: freeze the pager the
                      // moment the drag reads more up/down than sideways,
                      // so its horizontal recognizer stops tracking the
                      // stray dx of a sheet/dismiss swipe.
                      if (!_verticalDragLock &&
                          _dragDy.abs() > 16 &&
                          _dragDy.abs() > _dragDx.abs() * 1.2) {
                        setState(() => _verticalDragLock = true);
                      }
                      // Deliberate swipe-up: far enough, and clearly more
                      // vertical than horizontal.
                      if (_dragDy < -60 && _dragDy.abs() > _dragDx.abs() * 1.5) {
                        _sheetTriggered = true;
                        _showDetailsSheet();
                        return;
                      }
                      // Deliberate swipe-down: start the drag-follow close.
                      if (_dragDy > 24 && _dragDy > _dragDx.abs() * 1.5) {
                        setState(() {
                          _dismissDragging = true;
                          _dismissDy = _dragDy;
                        });
                      }
                    },
                    onPointerUp: (_) {
                      _activePointers = max(0, _activePointers - 1);
                      if (_activePointers == 0) {
                        _sheetTriggered = false;
                        // Unfreeze only when ALL fingers lift — the finger
                        // left over from a pinch must not fling the pager.
                        if (_multiTouch || _verticalDragLock) {
                          setState(() {
                            _multiTouch = false;
                            _verticalDragLock = false;
                          });
                        }
                        if (_dismissDragging) _endDismissDrag();
                      }
                    },
                    onPointerCancel: (_) {
                      _activePointers = max(0, _activePointers - 1);
                      if (_activePointers == 0) {
                        _sheetTriggered = false;
                        if (_multiTouch ||
                            _verticalDragLock ||
                            _dismissDragging) {
                          setState(() {
                            _multiTouch = false;
                            _verticalDragLock = false;
                            _dismissDragging = false;
                            _dismissDy = 0;
                          });
                        }
                      }
                    },
                    child: GestureDetector(
                      onTap: () {
                        setState(() => _showControls = !_showControls);
                        // The strip is unmounted while hidden and would
                        // otherwise reappear scrolled to the first item.
                        if (_showControls) _restoreStripPosition();
                      },
                      // Drag-follow + Samsung-style shrink. Instant
                      // (zero-duration) while the finger is down; the same
                      // widgets animate the snap-back on release.
                      child: AnimatedSlide(
                        offset: Offset(
                            0,
                            _dismissDy /
                                MediaQuery.sizeOf(context).height),
                        duration: _dismissDragging
                            ? Duration.zero
                            : const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        child: AnimatedScale(
                          scale: (1 -
                                  _dismissDy /
                                      MediaQuery.sizeOf(context).height *
                                      0.25)
                              .clamp(0.8, 1.0),
                          duration: _dismissDragging
                              ? Duration.zero
                              : const Duration(milliseconds: 200),
                          curve: Curves.easeOutCubic,
                          child: PageView.builder(
                          controller: _pageController,
                          // Build current ±1: neighbours preload + decode
                          // their full image before the swipe arrives, so
                          // the handoff is milliseconds, Samsung-style.
                          // Bounded (3 live pages), unlike the old
                          // keep-alive that retained every visited page.
                          allowImplicitScrolling: true,
                          // While zoomed, horizontal drags pan the image,
                          // not the pager; while pinching or mid vertical
                          // swipe, the pager must not drag underneath the
                          // gesture.
                          physics: _isZoomed || _multiTouch || _verticalDragLock
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
                              // change, and every video lands muted and
                              // playing (no inherited pause intent).
                              _videoExpanded = false;
                              _videoMuted = true;
                              _videoPauseIntent = false;
                            });
                            _loadVideoDurationHint();
                            // FIX: Sync filmstrip when swiping main photo
                            _scrollToIndex(index);
                            widget.onIndexChanged?.call(index);
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
                                onEdgeOvershoot: _handleEdgeOvershoot,
                                onVideoBinding: _onVideoBinding,
                                // Scrubbing (expanded strip) and a user
                                // pause both suppress the stall loader +
                                // auto-resume.
                                videoUiHold:
                                    _videoPauseIntent || _videoExpanded,
                              ),
                            );
                          },
                          ),
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
            if (!widget.standalone)
              SizedBox(
                height: _stripBarHeight,
                // Width MUST be pinned: with a loose width, the Stack
                // shrink-wraps its only non-positioned child — the 2.5 px
                // playhead — collapsing the whole bar to a sliver the moment
                // a video expands (and poisoning _stripViewport for all the
                // centering math afterwards).
                width: double.infinity,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Positioned.fill(
                      child: _buildFilmstrip(axis: Axis.horizontal),
                    ),
                    // Fixed center playhead: in expanded mode the FILM
                    // moves, the line doesn't (Samsung).
                    if (_videoExpanded && _activeVideo != null)
                      IgnorePointer(
                        child: Container(
                          width: 2.5,
                          height: _thumbH + 14,
                          decoration: BoxDecoration(
                            color: overlayColor,
                            borderRadius: BorderRadius.circular(2),
                            // Halo in the opposite tone — the line rides
                            // over photo frames, which can match either
                            // mode.
                            boxShadow: [
                              BoxShadow(
                                color: theme.colorScheme.surface
                                    .withValues(alpha: 0.7),
                                blurRadius: 2,
                              ),
                            ],
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
    // The SizedBox sits OUTSIDE the SafeArea, so a right-mounted nav bar
    // must be added here or it eats into the 80 px content lane.
    final railWidth = 80 + MediaQuery.paddingOf(context).right;
    final actionBar = Container(
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
    );
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      child: SizedBox(
        width: railWidth,
        child: SafeArea(
          left: false,
          // extendBodyBehindAppBar: start below the toolbar (SafeArea has
          // already added the status bar) so the rail never sits under the
          // AppBar's action icons.
          child: Padding(
            padding: const EdgeInsets.only(top: kToolbarHeight),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Under 380 px (phone landscape) the pill row + action bar
                // alone can exceed the rail, so go compact. Above it the
                // tree is the original one.
                if (constraints.maxHeight < 380) {
                  return _buildCompactRail(
                      theme, overlayColor, actionBar, constraints.maxHeight);
                }
                return Column(
                  children: [
                    if (_currentIsVideo)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child:
                            _buildVideoPillRow(overlayColor, vertical: true),
                      ),
                    if (widget.standalone)
                      const Spacer()
                    else
                      Expanded(
                        child: _buildFilmstrip(axis: Axis.vertical),
                      ),
                    actionBar,
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Phone-landscape rail: 40 px buttons, 2 px pill gaps, and the strip
  /// sized to whatever is left. The fixed parts are ESTIMATED as generous
  /// upper bounds: an overestimate only shortens the strip, an
  /// underestimate only makes the rail scroll a few px. Nothing overflows.
  Widget _buildCompactRail(ThemeData theme, Color overlayColor,
      Widget actionBar, double maxHeight) {
    // 8 top + pill (~71) + capture 38 + mute 38 + two 2 px gaps, rounded up.
    const pillRowEstimate = 170.0;
    final buttonCount =
        widget.fromRecycleBin ? 3 : (_currentIsVideo ? 4 : 5);
    // Margins 12 + padding 12 + 40 per compact IconButton, plus 8 slack.
    final barEstimate = 32.0 + 40.0 * buttonCount;
    final stripH =
        maxHeight - barEstimate - (_currentIsVideo ? pillRowEstimate : 0.0);
    final showStrip = !widget.standalone && stripH >= 48;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_currentIsVideo)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _buildVideoPillRow(overlayColor,
                  vertical: true, verticalGap: 2),
            ),
          if (showStrip)
            SizedBox(
              height: stripH,
              child: _buildFilmstrip(axis: Axis.vertical),
            )
          else
            // Keeps the bar bottom-aligned when there is no strip.
            SizedBox(height: stripH < 0 ? 0.0 : stripH),
          // Compact density drops each IconButton's 48 px tap target to
          // 40 px without touching the shared button builder.
          Theme(
            data: theme.copyWith(visualDensity: VisualDensity.compact),
            child: actionBar,
          ),
        ],
      ),
    );
  }

  // ---- Samsung-style video controls: frame-capture on the left, the
  // play/pause + time pill centered, mute on the right. All translucent,
  // floating straight over the photo.
  Widget _buildVideoPillRow(Color overlayColor,
      {required bool vertical, double verticalGap = 6}) {
    final pill = _VideoPill(
      controller: _activeVideo,
      durationHint: _videoDurationHint,
      vertical: vertical,
      onPlayPause: _handlePlayPause,
    );
    // Frame capture mints a NEW LIVE vault file — an edit affordance, so it
    // is hidden in bin mode (playback and mute stay: viewing, not editing).
    final capture = widget.fromRecycleBin
        ? null
        : _GlassIconButton(
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
          if (capture != null) ...[
            SizedBox(height: verticalGap),
            capture,
          ],
          SizedBox(height: verticalGap),
          mute,
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          // The slot stays even without the button so the pill keeps its
          // centered layout.
          SizedBox(
              width: 44,
              child: capture == null ? null : Center(child: capture)),
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
      Notify.info('Frame saved to vault');
    } catch (e) {
      // Same save path as the editor — same typed surfacing.
      final err = e is CnestError ? e : UploadPipeline.mapUploadError(e);
      if (mounted) {
        await showCnestError(context, err);
      } else {
        Notify.error(err.title);
      }
    }
  }

  Future<void> _handlePlayPause() async {
    final controller = _activeVideo;
    if (controller == null) {
      // Not initialized yet — ask the focused page to spin up playback.
      setState(() => _videoPauseIntent = false);
      await _activeVideoInit?.call();
      await _activeVideo?.setVolume(_videoMuted ? 0 : 1);
      return;
    }
    final value = controller.value;
    if (value.isPlaying) {
      setState(() => _videoPauseIntent = true);
      controller.pause();
    } else {
      setState(() => _videoPauseIntent = false);
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
      _preloadScrubFrames();
    });
  }

  /// Kick off scrub-film frame extraction as soon as a video binds, so the
  /// film is already painted when the user expands the thumb.
  void _preloadScrubFrames() {
    final controller = _activeVideo;
    if (controller == null || _currentFiles.isEmpty || !_currentIsVideo) {
      return;
    }
    final duration = controller.value.duration;
    if (duration <= Duration.zero) return;
    final file = _currentFiles[_currentIndex];
    String? source;
    if (file.localPath != null && File(file.localPath!).existsSync()) {
      source = file.localPath;
    } else {
      source = controller.dataSource;
    }
    unawaited(_ExpandedVideoStripState.preloadFrames(
      fileId: file.id,
      source: source,
      duration: duration,
      frameCount: _expandedFrameCount(duration),
    ));
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
        // Ignore degenerate transitional layouts — a poisoned viewport
        // breaks every centering computation until the next good layout.
        if (viewport > 50) _stripViewport = viewport;
        double leadPad = _currentFiles.isEmpty
            ? 0.0
            : max(0.0, (viewport - _slotWidth(0)) / 2);
        double trailPad = _currentFiles.isEmpty
            ? 0.0
            : max(0.0,
                (viewport - _slotWidth(_currentFiles.length - 1)) / 2);
        // While a video is expanded, the pads must also let fraction 0 and
        // fraction 1 of the segment reach the fixed center playhead —
        // otherwise the scroll hits its extents and scrubbing "sticks"
        // partway through the video.
        if (axis == Axis.horizontal &&
            _videoExpanded &&
            _activeVideo != null &&
            _currentFiles.isNotEmpty) {
          final segStart = _slotStart(_currentIndex) + 3;
          final segWidth =
              _expandedFrameCount(_activeVideo!.value.duration) *
                  _expandedTileWidth;
          final lastIndex = _currentFiles.length - 1;
          final total = _slotStart(lastIndex) + _slotWidth(lastIndex);
          leadPad = max(leadPad, viewport / 2 - segStart);
          trailPad =
              max(trailPad, viewport / 2 - (total - (segStart + segWidth)));
        }
        if (viewport > 50) _stripLeadPad = leadPad;

        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollStartNotification &&
                notification.dragDetails != null) {
              _userScrollingStrip = true;
            } else if (notification is ScrollEndNotification) {
              final wasUser = _userScrollingStrip;
              _userScrollingStrip = false;
              if (wasUser) {
                if (_videoExpanded) {
                  _finishScrub();
                } else {
                  _snapStripToNearest();
                }
              }
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
            tileWidth: _expandedTileWidth,
            // Slightly taller than the regular thumbs — Samsung's expanded
            // film pops out of the row.
            height: _thumbH + 6,
            radius: radius,
            // Second tap on the expanded film contracts it back to the
            // single thumb; scrolling the bar remains the way to scrub.
            onTap: _collapseCurrentVideo,
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
                          // The badge marks non-selected videos; the current
                          // one is marked by the playhead line instead.
                          if (isVideo && !isSelected)
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
                                  child: ThemeIcon(
                                    'play',
                                    selected: true,
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
                    ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: _activeVideo!,
                      builder: (_, value, _) {
                        final total = value.duration.inMilliseconds;
                        final fraction = total == 0
                            ? 0.0
                            : (value.position.inMilliseconds / total)
                                .clamp(0.0, 1.0);
                        // Explicit left offset — an aligned OverflowBox
                        // fills the parent, pinning the line to center.
                        return Positioned(
                          top: -4,
                          bottom: -4,
                          left: fraction * (thumbW - 2.5),
                          child: IgnorePointer(
                            child: Container(
                              width: 2.5,
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.onSurface,
                                borderRadius: BorderRadius.circular(2),
                                boxShadow: [
                                  BoxShadow(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surface
                                        .withValues(alpha: 0.7),
                                    blurRadius: 2,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
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
    final danger = Theme.of(context).colorScheme.error;
    // Bin mode: Restore / Info / Delete forever, nothing else.
    if (widget.fromRecycleBin) {
      final children = <Widget>[
        IconButton(
          icon: ThemeIcon('arrowCounterClockwise'),
          onPressed: _handleRestore,
          color: overlayColor,
        ),
        IconButton(
          icon: ThemeIcon('info'),
          onPressed: _showDetailsSheet,
          color: overlayColor,
        ),
        IconButton(
          icon: ThemeIcon('trash'),
          onPressed: _handleDelete,
          color: danger,
        ),
      ];
      if (vertical) {
        return Column(mainAxisSize: MainAxisSize.min, children: children);
      }
      return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: children);
    }
    // Samsung Gallery's order: favorite, edit, info, share, delete.
    final children = <Widget>[
      IconButton(
        icon: ThemeIcon('heart', selected: fav),
        onPressed: _toggleFavorite,
        color: fav ? danger : overlayColor,
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
        onPressed: () {
          final file = _currentFiles[_currentIndex];
          showShareChoiceSheet(context, file,
              onSecureLink: () => ShareDialog.show(context, file));
        },
        color: overlayColor,
      ),
      // Copy/Print/Wallpaper live in the AppBar's overflow menu — one
      // overflow surface, not two. Rename lives in the info sheet's Edit
      // button for the same reason.
      IconButton(
        icon: ThemeIcon('trash'),
        onPressed: _handleDelete,
        color: danger,
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
  final String icon;
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
    final radius = BorderRadius.circular(ThemeController().tokens.rCard);
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: radius,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: cs.outline),
        ),
        child: Row(
          children: [
            ThemeIcon(
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

  /// False in recycle-bin mode: renaming a binned file is a zombie edit.
  final bool canEdit;
  const _InfoSheetBody({
    required this.file,
    required this.scrollController,
    required this.onEdit,
    this.canEdit = true,
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

  String _fmtSize(int bytes) => formatBytes(bytes);

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
            if (widget.canEdit)
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
            fontFamily: ThemeController().tokens.monoFontFamily,
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
      // Scrollable so the keyboard in landscape can't overflow the dialog.
      content: SingleChildScrollView(
        child: Column(
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
          borderRadius: BorderRadius.circular(ThemeController().tokens.rPill),
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

  /// Zoomed pan dragged past the photo's horizontal edge by a deliberate
  /// margin — Samsung turns the page. direction: +1 next, −1 previous.
  final ValueChanged<int> onEdgeOvershoot;

  /// True while the user is deliberately holding playback (dock pause or
  /// scrub in progress). Suppresses the buffering loader and auto-resume —
  /// a stall during a USER pause must stay a pause.
  final bool videoUiHold;

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
    required this.onEdgeOvershoot,
    required this.onVideoBinding,
    this.videoUiHold = false,
  });

  @override
  State<_SinglePhotoView> createState() => _SinglePhotoViewState();
}

// NO AutomaticKeepAliveClientMixin — deliberately. Keep-alive retained
// EVERY visited page's full-res bytes plus its live VideoPlayerController
// and streaming session until route exit: measured +17-20 MB PSS per
// swipe on the A55 (682→855 MB in ten swipes, PERF.md S2) — an LMK/OOM
// path on budget devices. With default PageView semantics a page leaving
// the cache window is DISPOSED (dispose() already frees the controller and
// ends the streaming session), and returning to it re-reads the disk-backed
// caches (thumb_/decrypted files) — a cheap decode, not a re-download.
class _SinglePhotoViewState extends State<_SinglePhotoView>
    with SingleTickerProviderStateMixin {
  Uint8List? _fullImage;
  Uint8List? _thumbImage;
  // Rung 1 placeholder bytes — MediaStore thumbnail.
  Uint8List? _assetThumbBytes;
  bool _isLoadingFull = true;
  // Nothing local, nothing cached, nothing in the cloud — a phantom entry
  // (e.g. interrupted auto-sync upload whose gallery copy was later
  // deleted). Renders a broken-image state instead of spinning forever.
  bool _loadFailed = false;
  // The blob exists (op says so) but this device can't decrypt it yet — still
  // propagating through the provider. Distinct from _loadFailed: this is the
  // normal eventual-consistency case and self-heals on the next sync/open, so
  // it shows a calm "Syncing…" state, never a broken-image.
  bool _syncing = false;
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

  // ---- Raw-pointer pinch/pan engine ----
  // No InteractiveViewer: its ScaleGestureRecognizer had to WIN the gesture
  // arena against the PageView's horizontal drag, and the drag claims the
  // gesture as soon as the first finger crosses touch slop — usually before
  // the second finger lands — leaving the pinch dead until all fingers
  // lift. Raw Listeners never enter the arena, so every pinch registers.
  // The parent freezes the pager while two fingers are down, so nothing
  // fights the gesture.
  final Map<int, Offset> _touches = {};
  Matrix4 _gestureBase = Matrix4.identity();
  double? _pinchBaseSpan;
  Offset? _pinchBaseFocal;
  Offset? _panBasePoint;
  Size? _viewportSize;
  // One page turn per gesture: a zoomed pan that keeps pulling past the
  // photo's edge flips the page once, then goes quiet until fingers lift.
  bool _edgeTurnFired = false;

  bool get _isZoomedNow => _zoomCtrl.value.getMaxScaleOnAxis() > 1.01;

  void _onZoomPointerDown(PointerDownEvent event) {
    _touches[event.pointer] = event.localPosition;
    if (_touches.length == 1) _edgeTurnFired = false;
    if (_touches.length == 2) {
      _zoomAnim.stop();
      final pts = _touches.values.toList();
      _gestureBase = _zoomCtrl.value.clone();
      _pinchBaseSpan = (pts[0] - pts[1]).distance;
      _pinchBaseFocal = (pts[0] + pts[1]) / 2;
      _panBasePoint = null;
      return;
    }
    if (_touches.length == 1 && _isZoomedNow) {
      _zoomAnim.stop();
      _gestureBase = _zoomCtrl.value.clone();
      _panBasePoint = event.localPosition;
    }
  }

  void _onZoomPointerMove(PointerMoveEvent event) {
    if (!_touches.containsKey(event.pointer)) return;
    _touches[event.pointer] = event.localPosition;

    if (_touches.length >= 2) {
      final baseSpan = _pinchBaseSpan;
      final baseFocal = _pinchBaseFocal;
      if (baseSpan == null || baseFocal == null || baseSpan <= 0) return;
      final pts = _touches.values.toList();
      final span = (pts[0] - pts[1]).distance;
      final focal = (pts[0] + pts[1]) / 2;
      // Clamp TOTAL scale to [1, 4], then apply the allowed factor around
      // the focal point — the pinched spot stays under the fingers, and
      // two-finger drags pan because the focal midpoint moves.
      final baseScale = _gestureBase.getMaxScaleOnAxis();
      final factor =
          ((span / baseSpan) * baseScale).clamp(1.0, 4.0) / baseScale;
      final around = Matrix4.identity()
        ..translateByDouble(focal.dx, focal.dy, 0, 1)
        ..scaleByDouble(factor, factor, 1, 1)
        ..translateByDouble(-baseFocal.dx, -baseFocal.dy, 0, 1);
      _zoomCtrl.value = _clampToBounds(around * _gestureBase);
      return;
    }

    final panBase = _panBasePoint;
    if (panBase == null) return;
    final delta = event.localPosition - panBase;
    final desired =
        Matrix4.translationValues(delta.dx, delta.dy, 0) * _gestureBase
            as Matrix4;
    final clamped = _clampToBounds(desired);
    _zoomCtrl.value = clamped;

    // Samsung edge handoff: the horizontal drag the clamp swallowed. Once
    // it exceeds a deliberate margin the user is pulling PAST the edge —
    // turn the page. Negative overshoot = photo at its right edge, finger
    // swiping left → next; positive = at left edge, swiping right → prev.
    final overshoot = desired.storage[12] - clamped.storage[12];
    if (!_edgeTurnFired && overshoot.abs() > 80) {
      _edgeTurnFired = true;
      widget.onEdgeOvershoot(overshoot < 0 ? 1 : -1);
    }
  }

  void _onZoomPointerEnd(PointerEvent event) {
    if (_touches.remove(event.pointer) == null) return;
    if (_touches.length == 1) {
      // Pinch → one finger: hand off to pan without a jump.
      _gestureBase = _zoomCtrl.value.clone();
      _panBasePoint = _touches.values.first;
      _pinchBaseSpan = null;
      _pinchBaseFocal = null;
      return;
    }
    if (_touches.isNotEmpty) return;
    _panBasePoint = null;
    _pinchBaseSpan = null;
    _pinchBaseFocal = null;
    // Nearly-rest zoom settles to identity so the pager unlocks cleanly;
    // _animateZoomTo reports the level when the animation completes.
    if (_zoomCtrl.value.getMaxScaleOnAxis() < 1.05) {
      _animateZoomTo(Matrix4.identity());
      return;
    }
    _reportZoom();
  }

  /// Keeps the (viewport-sized, BoxFit.contain) content covering the
  /// viewport: at scale s the child spans s× the viewport, so a translation
  /// may not exceed 0 nor fall below extent·(1−s).
  Matrix4 _clampToBounds(Matrix4 m) {
    final size = _viewportSize;
    if (size == null) return m;
    final s = m.getMaxScaleOnAxis();
    final out = m.clone();
    out.storage[12] = out.storage[12].clamp(size.width * (1 - s), 0.0);
    out.storage[13] = out.storage[13].clamp(size.height * (1 - s), 0.0);
    return out;
  }

  // Double-tap zoom animation (Samsung: 2.5x centered on the tap point).
  late final AnimationController _zoomAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<Matrix4>? _zoomTween;
  TapDownDetails? _doubleTapDetails;

  @override
  void initState() {
    super.initState();
    _zoomAnim.addListener(_applyZoomAnim);
    _checkFileType();
    // Seed the placeholder synchronously from the grid's session memo so
    // the hero flight lands on the exact pixels the tile showed — never a
    // black frame, never a loader over a photo that was just on screen.
    final seedBytes = GalleryGridItem.memoAssetBytes(widget.file.id);
    if (seedBytes != null) {
      _assetThumbBytes = seedBytes;
    } else {
      final seedPath = GalleryGridItem.memoDiskPath(widget.file.id);
      if (seedPath != null) {
        try {
          _thumbImage = File(seedPath).readAsBytesSync();
        } catch (_) {}
      }
    }
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

  /// Reported only when a gesture/animation ENDS. Live transform updates
  /// repaint just the zoom surface (AnimatedBuilder); this flips the
  /// parent's page/dismiss gating, which rebuilds the pager — harmless
  /// between gestures, noisy during one.
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
  /// Asset-bound files skip the write — MediaStore IS their cache, and
  /// persisting a copy just inflates the app cache for nothing.
  void _persistVideoFrame(Uint8List bytes) {
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
    // Stall = buffering while the user WANTS playback. The old condition
    // required isPlaying too — but ExoPlayer drops isPlaying on a buffer
    // underrun, so the loader never showed and the frozen frame read as a
    // silent pause. Intent (videoUiHold) is what distinguishes "user
    // paused/scrubbing" from "network starved the buffer".
    final wasStalled = _isVideoStalled;
    final stalled =
        value.isBuffering && widget.isFocused && !widget.videoUiHold;
    if (stalled != _isVideoStalled && mounted) {
      setState(() => _isVideoStalled = stalled);
    }
    // Coming OUT of an underrun ExoPlayer can land on isPlaying=false —
    // before this the user had to press play manually after every stall.
    // Resume only on that edge, never at end-of-video, never against a
    // user hold.
    if (wasStalled &&
        !stalled &&
        !value.isBuffering &&
        !value.isPlaying &&
        widget.isFocused &&
        !widget.videoUiHold &&
        value.duration > Duration.zero &&
        value.position < value.duration) {
      _videoController?.play();
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

  Future<void> _loadImages() => trace('viewerLoadImages', _loadImagesImpl);

  Future<void> _loadImagesImpl() async {
    if (!mounted) return;

    // STEP 1 — placeholder, launched CONCURRENTLY with the full load:
    // neither waits on the other; whichever is ready first paints (the
    // grid-memo seed usually already painted frame 1).
    unawaited(_loadPlaceholder());

    // STEP 2 — full image. Local original wins ONLY when the content guard
    // verifies it matches the vault entry (size gate always; hash for
    // images) — a bare localPath might point at stale/different bytes.
    if (widget.file.localPath != null) {
      final localFile = File(widget.file.localPath!);
      if (await localFile.exists() &&
          await LocalContentGuard.matches(widget.file, localFile: localFile)) {
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
      // No cloud blob linked yet. Two very different cases:
      //  * A peer's createFile op materialized this row but reconcile hasn't
      //    joined the blob yet — the normal cross-device case, still
      //    propagating → calm "Syncing…". applyMergedState ALWAYS inserts
      //    those with is_uploaded = 1, so that flag is the discriminator.
      //  * A true phantom: no local copy (checked above), nothing cached,
      //    is_uploaded = 0 — an upload that never completed (the old
      //    "size > 0 ⇒ propagating" test read a failed save-as-copy row,
      //    which has a real size and a null hash, as a peer's op and showed
      //    "Syncing…" forever) → broken state ends the spinner honestly.
      final stillPropagating = widget.file.isUploaded;
      if (mounted) {
        setState(() {
          _isLoadingFull = false;
          if (stillPropagating) {
            _syncing = true;
          } else {
            _loadFailed = true;
          }
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
      // Never cache an empty result — treat as still-syncing and retry.
      if (decryptedBytes.isEmpty) {
        if (mounted) {
          setState(() {
            _isLoadingFull = false;
            _syncing = true;
          });
        }
        return;
      }
      await fullFile.writeAsBytes(decryptedBytes, flush: true);

      if (mounted) {
        setState(() {
          _fullImage = decryptedBytes;
          _isLoadingFull = false;
        });
        widget.onLoaded(widget.index);
      }
    } catch (e) {
      // Download/decrypt failed — usually the blob is still propagating to
      // this device. Calm "Syncing…", retried on the next sync/open.
      if (mounted) {
        setState(() {
          _isLoadingFull = false;
          _syncing = true;
        });
      }
    }
  }

  /// Three-rung placeholder. Whichever rung produces bytes first wins and the
  /// rest are skipped. Rung 2 (local original) doesn't set state — build()
  /// renders it directly via Image.file when localPath exists.
  Future<void> _loadPlaceholder() async {
    // RUNG 0 (videos only) — the shared disk thumb cache. MediaStore-bound
    // files skip it: Android serves their frame (rung 1), and a disk thumb
    // here can only be a stale leftover from a window when the local
    // original was missing — serving it first kept the leftover alive.
    if (_isVideo && widget.file.assetId == null) {
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
      // Zero network, zero decryption. Content-guard gated — a same-path
      // different-bytes file must never masquerade as the vault entry.
      VideoPlayerController? controller;
      if (widget.file.localPath != null) {
        final localFile = File(widget.file.localPath!);
        if (await localFile.exists() &&
            await LocalContentGuard.matches(widget.file,
                localFile: localFile)) {
          controller = VideoPlayerController.file(localFile);
          // Local original is authoritative again (restore-to-gallery):
          // the streamed chunk cache is dead weight — reclaim it.
          unawaited(CacheManagerService().invalidateLargePlaintext(
            fileId: widget.file.id,
            cloudId: widget.file.cloudId,
          ));
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
        Notify.error("Couldn't play this video: $short");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
            IgnorePointer(
              child: Center(
                child: CircularProgressIndicator(
                  color: Theme.of(context).colorScheme.primary,
                ),
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

    // Only the FOCUSED page may fly: during an edge-back gesture the
    // pager can sit between two pages, and without this gate BOTH pages'
    // heroes launched on pop (the double fly-back). Preloaded neighbours
    // (allowImplicitScrolling) would even make it three.
    return HeroMode(
      enabled: widget.isFocused,
      child: Stack(
      fit: StackFit.expand,
      children: [
        // A+B. One zoom surface for placeholder AND full image — a single
        // shared transform, so the zoom level can't jump when the
        // cross-fade swaps layers. Zoom/pan are driven by the raw-pointer
        // engine above (see its comment for why there's no
        // InteractiveViewer); the AnimatedBuilder repaints ONLY this
        // subtree per frame, so a pinch never rebuilds the pager.
        // Disabled for videos: their placeholder isn't zoomable.
        // Double-tap = Samsung 2.5x.
        GestureDetector(
          onDoubleTapDown:
              _isVideo ? null : (details) => _doubleTapDetails = details,
          onDoubleTap: _isVideo ? null : _handleDoubleTap,
          child: Listener(
            onPointerDown: _isVideo ? null : _onZoomPointerDown,
            onPointerMove: _isVideo ? null : _onZoomPointerMove,
            onPointerUp: _isVideo ? null : _onZoomPointerEnd,
            onPointerCancel: _isVideo ? null : _onZoomPointerEnd,
            behavior: HitTestBehavior.opaque,
            child: LayoutBuilder(
              builder: (context, constraints) {
                _viewportSize =
                    Size(constraints.maxWidth, constraints.maxHeight);
                // Hero pairs with the grid tile: the photo expands out
                // of its cell and returns to it on close. The hero wraps
                // the image's REAL display rect (Center + AspectRatio)
                // when dimensions are known, so the flight morphs the
                // grid's square crop into the photo's true aspect — never
                // ballooning to full screen first. Unknown dimensions
                // fall back to the fullscreen hero.
                final dimW = widget.file.width;
                final dimH = widget.file.height;
                final aspect =
                    (dimW != null && dimH != null && dimW > 0 && dimH > 0)
                        ? dimW / dimH
                        : null;
                // contain, not cover: stored dimensions can be raw
                // (pre-EXIF-rotation), and cover would CROP such a photo
                // at rest. With correct metadata contain == cover inside
                // this exact-aspect box; with wrong metadata the photo
                // letterboxes instead of losing pixels.
                const fit = BoxFit.contain;
                final photo = Stack(
            fit: StackFit.expand,
            children: [
              // Placeholder — first rung that's ready wins. Local originals
              // are only decodable for images; a video's rung-2 frame is
              // extracted in _loadPlaceholder and arrives as _assetThumbBytes.
              if (_assetThumbBytes != null)
                Image.memory(
                  _assetThumbBytes!,
                  fit: fit,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                )
              else if (hasLocal && !_isVideo)
                // Stays in the tree even after _fullImage arrives — removing
                // it while the full JPEG was still decoding was the black
                // flicker on local-gallery photos.
                Image.file(
                  localFile,
                  fit: fit,
                  cacheWidth: 300,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                )
              else if (_thumbImage != null)
                Image.memory(
                  _thumbImage!,
                  fit: fit,
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
                  fit: fit,
                  gaplessPlayback: true,
                  // Bound the decoded bitmap: at max zoom (4x) a 1080-wide
                  // viewport never needs more than ~4320 source pixels, and
                  // 4096 is the safe GPU-texture ceiling. An unconstrained
                  // 50MP shot would otherwise decode to a ~200MB RGBA
                  // buffer on exactly the screen where memory is tightest.
                  cacheWidth: 4096,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  frameBuilder: (context, child, frame, wasSync) {
                    if (wasSync) return child;
                    return AnimatedOpacity(
                      opacity: frame == null ? 0.0 : 1.0,
                      // Same picture in two resolutions — a fast reveal,
                      // not a scene change.
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOut,
                      child: child,
                    );
                  },
                ),
            ],
                    );
                if (aspect == null) {
                  return Hero(
                    tag: 'photo-${widget.file.id}',
                    flightShuttleBuilder: photoHeroShuttle,
                    child: ClipRect(
                      child: AnimatedBuilder(
                        animation: _zoomCtrl,
                        builder: (context, child) => Transform(
                          transform: _zoomCtrl.value,
                          child: child,
                        ),
                        child: photo,
                      ),
                    ),
                  );
                }
                return ClipRect(
                  child: AnimatedBuilder(
                    animation: _zoomCtrl,
                    builder: (context, child) => Transform(
                      transform: _zoomCtrl.value,
                      child: child,
                    ),
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: aspect,
                        child: Hero(
                          tag: 'photo-${widget.file.id}',
                          flightShuttleBuilder: photoHeroShuttle,
                          child: photo,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),

        // (The old giant center play button is gone — playback starts from
        // the dock's pill, same as Samsung Gallery.)

        // D. Spinner (For Image or Video Buffering)
        // Spinner only when there is NOTHING to show — with any
        // placeholder on screen a loader over a local photo reads broken.
        if ((!_isVideo &&
                _isLoadingFull &&
                _fullImage == null &&
                _assetThumbBytes == null &&
                _thumbImage == null &&
                !hasLocal) ||
            _isBufferingVideo)
          Center(
            child: CircularProgressIndicator(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),

        // E. Syncing state — the blob exists but hasn't propagated to this
        // device yet (provider eventual-consistency). Calm and auto-resolving:
        // it re-fetches on the next sync/open, so it must never look broken.
        // Shown over the low-res thumb when we have one, else on its own.
        if (!_isVideo && _syncing && _fullImage == null)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ThemeIcon(
                  'arrowsClockwise',
                  color: Theme.of(context).colorScheme.onSurface.withAlpha(140),
                  size: 40,
                ),
                const SizedBox(height: 10),
                Text(
                  'Syncing…',
                  style: TextStyle(
                    color:
                        Theme.of(context).colorScheme.onSurface.withAlpha(140),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),

        // F. Broken state — nothing local, nothing cached, nothing in the
        // cloud (or the download failed). Matches the grid's broken tile.
        if (!_isVideo &&
            _loadFailed &&
            _fullImage == null &&
            _assetThumbBytes == null &&
            _thumbImage == null &&
            !hasLocal)
          Center(
            child: ThemeIcon(
              'imageBroken',
              color: Theme.of(context).colorScheme.onSurface.withAlpha(97),
              size: 64,
            ),
          ),
      ],
      ),
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
    // behind photo cells here. MediaStore-bound files skip it — for them a
    // disk thumb is only a stale leftover (see _loadPlaceholder rung 0).
    if (_isVideo &&
        widget.file.assetId == null &&
        widget.file.cloudId != null) {
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
  /// is also good enough as the viewer's placeholder. Skipped for
  /// asset-bound files — MediaStore already serves them.
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
    final placeholder = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget fallback(_, _, _) => Container(color: placeholder);

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
    return Container(color: placeholder);
  }
}

/// Samsung-style playback pill: play/pause glyph + "mm:ss / mm:ss". Always
/// shows the time — before the stream is ready it renders 00:00 over the
/// metadata duration hint (or --:-- as the last resort).
class _VideoPill extends StatelessWidget {
  final VideoPlayerController? controller;
  final Duration? durationHint;
  final bool vertical;
  final VoidCallback onPlayPause;
  const _VideoPill({
    required this.controller,
    required this.durationHint,
    required this.vertical,
    required this.onPlayPause,
  });

  static String _fmt(Duration? d) {
    if (d == null) return '--:--';
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _content({
    required bool playing,
    required Duration position,
    required Duration? duration,
  }) {
    final icon = ThemeIcon(
      playing ? 'pause' : 'play',
      selected: true,
      size: 20,
      color: Colors.white,
    );
    final positionText = Text(
      _fmt(position),
      style: TextStyle(
        color: Colors.white,
        fontSize: vertical ? 10 : 13,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final totalText = Text(
      vertical ? _fmt(duration) : ' / ${_fmt(duration)}',
      style: TextStyle(
        color: Colors.white60,
        fontSize: vertical ? 9 : 13,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    if (vertical) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [icon, const SizedBox(height: 2), positionText, totalText],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [icon, const SizedBox(width: 8), positionText, totalText],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final Widget content = c == null
        ? _content(
            playing: false,
            position: Duration.zero,
            duration: durationHint,
          )
        : ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: c,
            builder: (_, value, _) => _content(
              playing: value.isPlaying,
              position: value.position,
              duration: value.duration > Duration.zero
                  ? value.duration
                  : durationHint,
            ),
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

/// The expanded video segment inside the gallery bar: a dense film of frames
/// spread evenly across the full duration, extracted lazily and cached.
/// Scrubbing happens by scrolling the bar under the fixed center playhead;
/// tapping the film collapses it back to the single thumb.
class _ExpandedVideoStrip extends StatefulWidget {
  final CnestFile file;
  final String? source;
  final Duration duration;
  final int frameCount;
  final double tileWidth;
  final double height;
  final double radius;
  final VoidCallback onTap;

  const _ExpandedVideoStrip({
    super.key,
    required this.file,
    required this.source,
    required this.duration,
    required this.frameCount,
    required this.tileWidth,
    required this.height,
    required this.radius,
    required this.onTap,
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

  /// Extracts the film's frames into the shared cache. The screen calls this
  /// the moment a video binds — while the user is still watching the small
  /// thumb — so expansion opens onto a fully painted film instead of dark
  /// tiles filling in one by one.
  static Future<void> preloadFrames({
    required String fileId,
    required String? source,
    required Duration duration,
    required int frameCount,
    void Function()? onFrame,
  }) async {
    final key = '$fileId#$frameCount';
    _frameCache.putIfAbsent(
      key,
      () => List<Uint8List?>.filled(frameCount, null),
    );
    if (_extracting.contains(key)) return;
    if (source == null) return;
    final frames = _frameCache[key]!;
    if (!frames.contains(null)) return;
    _extracting.add(key);
    try {
      final totalMs = duration.inMilliseconds;
      for (var i = 0; i < frameCount; i++) {
        if (frames[i] != null) continue;
        try {
          final bytes = await VideoThumbnail.thumbnailData(
            video: source,
            imageFormat: ImageFormat.JPEG,
            timeMs: (totalMs * (i + 0.5) / frameCount).round(),
            maxWidth: 120,
            quality: 50,
          );
          frames[i] = bytes;
        } catch (_) {
          // Tile stays dark; keep extracting the rest.
        }
        onFrame?.call();
      }
    } finally {
      _extracting.remove(key);
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(preloadFrames(
      fileId: widget.file.id,
      source: widget.source,
      duration: widget.duration,
      frameCount: widget.frameCount,
      onFrame: () {
        if (mounted) setState(() {});
      },
    ));
  }

  @override
  Widget build(BuildContext context) {
    final frames = _frameCache[_cacheKey]!;
    final placeholder = Theme.of(context).colorScheme.surfaceContainerHighest;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
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
                              Container(color: placeholder),
                        )
                      : Container(color: placeholder),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
