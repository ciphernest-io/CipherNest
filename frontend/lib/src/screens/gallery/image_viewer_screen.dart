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
import 'package:chewie/chewie.dart';
import '../../config/theme.dart';
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
    // While the user is driving the strip, do NOT animateTo — it would fight
    // their drag/fling and cause stuttering.
    if (_userScrollingStrip) return;
    const itemSize = 48.0;
    // Strip is horizontal in portrait, vertical in landscape — center it
    // against whichever axis the user actually sees it scrolling along.
    final size = MediaQuery.of(context).size;
    final isLandscape = size.width > size.height;
    final viewportExtent = isLandscape ? size.height : size.width;
    final offset = (index * itemSize) - (viewportExtent / 2) + (itemSize / 2);

    _filmStripController.animateTo(
      offset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  /// Reads the strip's current scroll position, finds the item closest to
  /// screen-center, and jumps the main PageView to it. Called on every
  /// ScrollUpdateNotification while the user is dragging or the strip is
  /// settling from a fling.
  void _syncMainPageFromStrip() {
    if (!_filmStripController.hasClients || !_pageController.hasClients) return;
    const itemSize = 48.0;
    final size = MediaQuery.of(context).size;
    final isLandscape = size.width > size.height;
    final viewportExtent = isLandscape ? size.height : size.width;
    final offset = _filmStripController.offset;
    final centerIndex =
        ((offset + viewportExtent / 2 - itemSize / 2) / itemSize).round();
    final clamped = centerIndex.clamp(0, _currentFiles.length - 1);
    if (clamped == _currentIndex) return;
    // jumpToPage triggers onPageChanged which updates _currentIndex, but
    // _scrollToIndex inside that callback is suppressed by _userScrollingStrip.
    _pageController.jumpToPage(clamped);
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
                    onSelected: (val) {},
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
                    onPointerMove: (event) {
                      // Raw detection: if we move UP significantly, trigger sheet
                      if (event.delta.dy < -10) {
                        _showDetailsSheet();
                      }
                    },
                    child: GestureDetector(
                      onTap: () =>
                          setState(() => _showControls = !_showControls),
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
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 2.5),
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

  // ---- Portrait: filmstrip across the top of the bottom dock, action row
  // beneath it. Identical behaviour to the original layout.
  Widget _buildPortraitControls(ThemeData theme, Color overlayColor) {
    return Positioned(
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
              SizedBox(
                height: 56,
                child: _buildFilmstrip(axis: Axis.horizontal),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: _buildActionButtons(
                  overlayColor: overlayColor,
                  vertical: false,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Landscape: 80 px right-side rail. Filmstrip scrolls vertically on
  // top, action buttons stack below it. Both live inside SafeArea so the
  // gesture-nav bar / display cutout don't clip them.
  Widget _buildLandscapeControls(ThemeData theme, Color overlayColor) {
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      child: SizedBox(
        width: 80,
        child: Container(
          color: theme.colorScheme.surface.withOpacity(0.9),
          child: SafeArea(
            left: false,
            child: Column(
              children: [
                Expanded(
                  child: _buildFilmstrip(axis: Axis.vertical),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: _buildActionButtons(
                    overlayColor: overlayColor,
                    vertical: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilmstrip({required Axis axis}) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null) {
          _userScrollingStrip = true;
        } else if (notification is ScrollEndNotification) {
          _userScrollingStrip = false;
        }
        if (notification is ScrollUpdateNotification && _userScrollingStrip) {
          _syncMainPageFromStrip();
        }
        return false;
      },
      child: ListView.builder(
        controller: _filmStripController,
        scrollDirection: axis,
        itemCount: _currentFiles.length,
        padding: axis == Axis.horizontal
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 8)
            : const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        itemBuilder: (context, index) {
          final isSelected = index == _currentIndex;
          return GestureDetector(
            onTap: () => _pageController.jumpToPage(index),
            child: Container(
              // Match width on horizontal strip, height on vertical strip —
              // _scrollToIndex assumes a 48 px item extent on whichever axis.
              width: axis == Axis.horizontal ? 40 : null,
              height: axis == Axis.vertical ? 40 : null,
              margin: axis == Axis.horizontal
                  ? const EdgeInsets.symmetric(horizontal: 4)
                  : const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                border: isSelected
                    ? Border.all(color: AppColors.primary, width: 2)
                    : null,
              ),
              child: _FilmstripItem(
                key: ValueKey(_currentFiles[index].id),
                file: _currentFiles[index],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildActionButtons({
    required Color overlayColor,
    required bool vertical,
  }) {
    final fav = _currentFiles[_currentIndex].isFavorite;
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
      // Edit — hidden for videos to keep the row balanced.
      if (!_currentIsVideo)
        IconButton(
          icon: ThemeIcon('pencilSimple'),
          onPressed: _openEditor,
          color: overlayColor,
        ),
      PopupMenuButton<String>(
        icon: Icon(
          themeIconData('dotsThreeVertical'),
          color: overlayColor,
        ),
        onSelected: (v) {
          switch (v) {
            case 'copy':
              _copyToClipboard();
              break;
            case 'print':
              _printCurrent();
              break;
            case 'wallpaper':
              _setAsWallpaper();
              break;
          }
        },
        // Rename lives in the info sheet's Edit button now — one place,
        // not two. Same button also lets the user correct the captured
        // date/time on an imported file.
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'copy', child: Text('Copy')),
          PopupMenuItem(value: 'print', child: Text('Print')),
          PopupMenuItem(value: 'wallpaper', child: Text('Set as wallpaper')),
        ],
      ),
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
  // Rung 1 placeholder bytes — MediaStore thumbnail.
  Uint8List? _assetThumbBytes;
  // Drives the cross-fade from placeholder to full image. Flipped 0 → 1 in a
  // post-frame callback after _fullImage is set so the AnimatedOpacity actually
  // animates instead of snapping.
  double _fullOpacity = 0.0;
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
          _triggerCrossFade();
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
        _triggerCrossFade();
        widget.onLoaded(widget.index);
      }
      return;
    }

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
          _triggerCrossFade();
          widget.onLoaded(widget.index);
        }
      } catch (e) {
        if (mounted) setState(() => _isLoadingFull = false);
      }
    }
  }

  /// Three-rung placeholder. Whichever rung produces bytes first wins and the
  /// rest are skipped. Rung 2 (local original) doesn't set state — build()
  /// renders it directly via Image.file when localPath exists.
  Future<void> _loadPlaceholder() async {
    // RUNG 1 — Android's MediaStore via photo_manager.
    if (widget.file.assetId != null) {
      try {
        final asset = await AssetEntity.fromId(widget.file.assetId!);
        if (asset != null) {
          final bytes = await asset.thumbnailDataWithSize(
            const ThumbnailSize(300, 300),
          );
          if (bytes != null) {
            if (mounted) setState(() => _assetThumbBytes = bytes);
            return;
          }
        }
      } catch (_) {
        // fall through
      }
    }

    // RUNG 2 — local original. No state to set; the build() picks it up if
    // localPath resolves to an existing file.
    if (widget.file.localPath != null &&
        File(widget.file.localPath!).existsSync()) {
      return;
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

  void _triggerCrossFade() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _fullOpacity = 1.0);
    });
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
      // Common failure modes:
      //   PlatformException(VideoError) — codec/container mismatch. Look at
      //     the underlying container extension.
      //   SocketException / TimeoutException — cloud provider not reachable.
      //   StateError('No cloud ID') — file never finished uploading.
      // Full detail goes to debugPrint; user sees a friendlier line.
      debugPrint('Video initialize failed: $e');
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
    final localFile = widget.file.localPath != null
        ? File(widget.file.localPath!)
        : null;
    final hasLocal = localFile != null && localFile.existsSync();

    return Stack(
      fit: StackFit.expand,
      children: [
        // A. Placeholder — first rung that's ready wins.
        if (_assetThumbBytes != null)
          InteractiveViewer(
            minScale: 1.0,
            maxScale: 4.0,
            child: Image.memory(
              _assetThumbBytes!,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          )
        else if (hasLocal && _fullImage == null)
          InteractiveViewer(
            minScale: 1.0,
            maxScale: 4.0,
            child: Image.file(
              localFile,
              fit: BoxFit.contain,
              cacheWidth: 300,
              gaplessPlayback: true,
            ),
          )
        else if (_thumbImage != null)
          InteractiveViewer(
            minScale: 1.0,
            maxScale: 4.0,
            child: Image.memory(
              _thumbImage!,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),

        // B. Full Image — cross-fades over the placeholder.
        if (!_isVideo && _fullImage != null)
          InteractiveViewer(
            minScale: 1.0,
            maxScale: 4.0,
            child: AnimatedOpacity(
              opacity: _fullOpacity,
              duration: ThemeController().tokens.dur,
              curve: ThemeController().tokens.easeOut,
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
                  themeIconData('play', selected: true),
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
  Uint8List? _assetThumbBytes;
  String? _diskThumbPath;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
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

    // Rung 2 — local original handled by build() directly.
    if (widget.file.localPath != null &&
        File(widget.file.localPath!).existsSync()) {
      if (mounted) setState(() {});
      return;
    }

    // Rung 3 — cached decrypted thumb on disk.
    if (widget.file.cloudId == null) return;
    final cacheDir = await getTemporaryDirectory();
    final f = File('${cacheDir.path}/thumb_${widget.file.cloudId}.jpg');
    if (await f.exists()) {
      if (mounted) setState(() => _diskThumbPath = f.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_assetThumbBytes != null) {
      return Image.memory(
        _assetThumbBytes!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }
    if (widget.file.localPath != null) {
      final f = File(widget.file.localPath!);
      if (f.existsSync()) {
        return Image.file(
          f,
          fit: BoxFit.cover,
          cacheWidth: 120,
          gaplessPlayback: true,
        );
      }
    }
    if (_diskThumbPath != null) {
      return Image.file(
        File(_diskThumbPath!),
        fit: BoxFit.cover,
        cacheWidth: 120,
        gaplessPlayback: true,
      );
    }
    return Container(color: Colors.grey[800]);
  }
}
