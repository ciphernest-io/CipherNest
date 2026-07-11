import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../widgets/theme_icon.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart'; 
import 'package:printing/printing.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:video_thumbnail/video_thumbnail.dart'; // NEW IMPORT
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/routes.dart';
import '../../config/theme_controller.dart';
import '../../widgets/account_switcher.dart';
import '../../widgets/ciphernest_logo.dart';

import '../../models/file_model.dart';
import '../../../services/cnest_errors.dart';
import '../../../services/database_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/cloud/account_registry.dart';
import '../../../services/encryption_service.dart';
import '../../../services/sync_service.dart';
import '../../widgets/friendly_error_sheet.dart';

enum _UploadCategory { media, document, audio, other }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _isUploading = false;
  bool _isLoadingSession = true;
  Map<String, int>? _vaultStats;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initSession();
    SyncService().syncNotifier.addListener(_refreshStats);
    // Any file mutation anywhere in the app (delete, upload, restore, album
    // move, edit) bumps DatabaseService's notifier — so vault usage updates
    // in place instead of only refreshing on cold start or after a full
    // sync round-trip. Also covers "user was on Settings deleting files,
    // popped back to Home, expects to see the new count immediately."
    DatabaseService().addListener(_refreshStats);
  }

  @override
  void dispose() {
    SyncService().syncNotifier.removeListener(_refreshStats);
    DatabaseService().removeListener(_refreshStats);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Immediate local recompute — SQLite is fast, don't make the user
      // wait for the cloud sync round-trip. syncNow's completion will
      // bump the numbers again if the cloud state moved.
      _refreshStats();
      SyncService().syncNow();
    }
  }

  Future<void> _refreshStats() async {
    final stats = await DatabaseService().getStorageStats();
    if (mounted) setState(() => _vaultStats = stats);
  }

  Future<void> _markSetupCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('setup_completed_v1', true);
  }

  Future<void> _initSession() async {
    setState(() => _isLoadingSession = true);

    // Reaching Home is the point at which "the user has finished setup at
    // least once" — this is the flag the splash gate reads next time to
    // distinguish "signed out, restore" from "closed mid-signup, onboard
    // again." Set idempotently on every home mount.
    unawaited(_markSetupCompleted());

    try {
      final active = AccountRegistry().activeAccount;
      String? email = active?.email;
      email ??= await CloudService().restoreSession();

      if (!mounted) return;
      if (active != null) {
        DatabaseService().setCurrentAccount(active.id);
        setState(() => _isLoadingSession = false);
        _refreshStats();
        SyncService().syncNow();
      } else if (email != null) {
        // Legacy edge case: no active account but a session exists.
        setState(() => _isLoadingSession = false);
        _refreshStats();
        SyncService().syncNow();
      } else {
        // Splash + login should have caught this and routed to reconnect,
        // but we defend against race conditions (token invalidated after
        // login success). Route rather than render an inline error.
        Navigator.pushReplacementNamed(context, AppRoutes.reconnect);
      }
    } catch (e, s) {
      debugPrint('Home _initSession failed: $e\n$s');
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, AppRoutes.reconnect);
    }
  }

  Future<Uint8List?> _generatePdfThumbnail(Uint8List fileBytes) async {
    try {
      await for (final page in Printing.raster(fileBytes, pages: [0], dpi: 72)) {
        final pdfImage = await page.toImage();
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final paint = Paint()..color = Colors.white;
        
        canvas.drawRect(
          Rect.fromLTWH(0, 0, pdfImage.width.toDouble(), pdfImage.height.toDouble()),
          paint
        );

        canvas.drawImage(pdfImage, Offset.zero, Paint());

        final compositedImage = await recorder.endRecording().toImage(
          pdfImage.width, 
          pdfImage.height
        );

        final byteData = await compositedImage.toByteData(format: ui.ImageByteFormat.png);
        if (byteData == null) return null;
        var pngBytes = byteData.buffer.asUint8List();

        final jpegBytes = await FlutterImageCompress.compressWithList(
           pngBytes,
           minHeight: 300,
           minWidth: 300,
           quality: 60,
           format: CompressFormat.jpeg,
        );
        return jpegBytes;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Resolves a FilePicker pick to the corresponding photo_manager
  /// AssetEntity so the vault entry ties back to the phone's gallery.
  /// Three tiers, tried in order:
  ///
  ///   1. `pickedIdentifier` — on Android, file_picker exposes the
  ///      `content://media/external/images/media/<id>` URI it opened. The
  ///      trailing integer IS the MediaStore id photo_manager keys on, so
  ///      `AssetEntity.fromId(id.toString())` returns the entity directly.
  ///      Zero enumeration; ~10 ms.
  ///
  ///   2. Global filename scan — pull the "all photos" album (the first
  ///      hit from `getAssetPathList` with no time filter) and walk it
  ///      until an entry's `title` matches the picked filename. Skips the
  ///      per-asset `await file.length()` — matching by name across the
  ///      whole gallery is enough in practice; collisions are effectively
  ///      zero because Android generates unique camera filenames.
  ///
  ///   3. Fallback — if the picker returned a direct `/storage/…` path
  ///      we can at least store that as `localPath`, even without an
  ///      assetId. Better than sending grid renders to the cloud.
  Future<_GalleryAssetMatch?> _resolveGalleryAsset({
    required String filename,
    required int fileSize,
    required String fallbackPath,
    String? pickedIdentifier,
  }) async {
    // TIER 1 — content URI → MediaStore id.
    if (pickedIdentifier != null) {
      final id = _extractMediaStoreId(pickedIdentifier);
      if (id != null) {
        try {
          final asset = await AssetEntity.fromId(id);
          if (asset != null) {
            final f = await asset.file;
            if (f != null) {
              return _GalleryAssetMatch(
                assetId: asset.id,
                localPath: f.path,
              );
            }
          }
        } catch (e) {
          debugPrint('AssetEntity.fromId($id) failed: $e');
        }
      }
    }

    // TIER 2 — filename scan across the whole gallery.
    try {
      final perm = await PhotoManager.requestPermissionExtend();
      if (perm.isAuth) {
        final albums = await PhotoManager.getAssetPathList(
          type: RequestType.common,
        );
        // `getAssetPathList` returns the "all photos" super-album first on
        // Android; walking it saves the per-album iteration the old code did.
        for (final album in albums) {
          final count = await album.assetCountAsync;
          if (count == 0) continue;
          // Bump the scan width — 200 was too tight for anything not
          // taken in the last week or so.
          final assets = await album.getAssetListRange(
            start: 0,
            end: count.clamp(0, 2000),
          );
          for (final a in assets) {
            if (a.title == filename) {
              final f = await a.file;
              if (f != null) {
                return _GalleryAssetMatch(
                  assetId: a.id,
                  localPath: f.path,
                );
              }
            }
          }
          // First (usually largest) album is enough — it's the aggregate
          // "Recent" / "All" album on both Samsung and stock Android.
          break;
        }
      }
    } catch (e) {
      debugPrint('_resolveGalleryAsset filename scan failed: $e');
    }

    // TIER 3 — direct-path fallback.
    if (fallbackPath.startsWith('/storage/') ||
        fallbackPath.startsWith('/sdcard/')) {
      return _GalleryAssetMatch(assetId: null, localPath: fallbackPath);
    }
    return null;
  }

  /// Pulls the trailing numeric id out of a `content://media/...` URI.
  /// Returns null if the URI doesn't look MediaStore-shaped.
  String? _extractMediaStoreId(String uri) {
    if (!uri.startsWith('content://media/')) return null;
    final trailing = uri.split('/').last;
    // Guard against query strings / fragments picked up by trailing.
    final digits = RegExp(r'^\d+').firstMatch(trailing)?.group(0);
    return digits;
  }

  Future<void> _handleUpload({required _UploadCategory category}) async {
    final isMedia = category == _UploadCategory.media;
    final isAudio = category == _UploadCategory.audio;
    final isOther = category == _UploadCategory.other;

    Uint8List? fileBytes;
    Stream<List<int>>? fileStream;
    int? fileSize;
    String filename = '';
    Uint8List? thumbnailBytes;
    bool isVideo = false;
    String? pickedPath;
    // Hoisted above the try so the catch block can roll back the DB
    // row that gets inserted in step 4 when a later step (upload) fails.
    String? fileId;

    try {
      // --- 1. UNIFIED PICKER (FilePicker Only) ---
      // "Other" deliberately opens the unrestricted system picker so users
      // can bring in zips, code files, ipynbs — anything they want vaulted.
      List<String>? exts;
      if (isMedia) {
        exts = ['jpg', 'jpeg', 'png', 'heic', 'webp', 'mp4', 'mov', 'avi', 'mkv'];
      } else if (isAudio) {
        exts = ['mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg', 'opus', 'wma'];
      } else if (isOther) {
        exts = null;
      } else {
        exts = ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt'];
      }
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: exts == null ? FileType.any : FileType.custom,
        allowedExtensions: exts,
        withData: false,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;

      final pickedFile = result.files.first;
      filename = pickedFile.name;
      fileSize = pickedFile.size;
      pickedPath = pickedFile.path; // Vital for cleanup

      if (pickedPath == null) throw Exception("Could not retrieve file path");

      // Validations
      final ext = filename.split('.').last.toLowerCase();
      isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(ext);

      // --- 2. PREPARE STREAM OR BYTES ---
      if (isVideo) {
        fileStream = File(pickedPath).openRead();
        
        try {
          final uint8list = await VideoThumbnail.thumbnailData(
            video: pickedPath,
            imageFormat: ImageFormat.JPEG,
            maxWidth: 300, 
            quality: 50,
          );
          thumbnailBytes = uint8list;
        } catch (e) {
          debugPrint("Video thumbnail generation failed: $e");
        }
      } else {
        fileBytes = await File(pickedPath).readAsBytes();
      }

      setState(() => _isUploading = true);

      // --- 3. GENERATE IMAGE/DOC THUMBNAILS ---
      if (!isVideo && fileBytes != null) {
        if (isMedia) {
           try {
            thumbnailBytes = await FlutterImageCompress.compressWithList(
              fileBytes,
              minHeight: 300,
              minWidth: 300,
              quality: 50,
            );
          } catch (e) {
            debugPrint("Image thumbnail failed: $e");
          }
        } else if (filename.toLowerCase().endsWith('.pdf')) {
          thumbnailBytes = await _generatePdfThumbnail(fileBytes);
        }
      }

      // --- 4. DATABASE ENTRY ---
      fileId = const Uuid().v4();
      CnestFileType type;
      if (isVideo || isMedia) {
        type = CnestFileType.image;
      } else if (isAudio) {
        type = CnestFileType.audio;
      } else if (isOther) {
        // Best-effort classify by extension so a music file the user picked
        // through "Other Files" still lands in the Audio tab, etc.
        type = CnestFileTypeWire.fromFilename(filename);
      } else {
        type = CnestFileType.document;
      }
      final currentEmail = CloudService().currentEmail;

      if (currentEmail == null) throw Exception('No active account.');

      // Detect if picked from local storage vs a cloud content provider
      final isLocalFile = pickedPath.startsWith('/storage/') || pickedPath.startsWith('/sdcard/');

      // Try to resolve to a photo_manager AssetEntity so the vault entry
      // ties back to the phone's gallery. Two wins: (1) smart albums like
      // "Camera" can match by MediaStore bucket rather than filename hacks,
      // and (2) the grid uses MediaStore thumbnails via assetId — no need
      // to decrypt + cache a copy just to render a preview. Only relevant
      // for media picks; other types have no MediaStore entry.
      String? matchedAssetId;
      String? matchedLocalPath;
      if (isMedia) {
        final match = await _resolveGalleryAsset(
          filename: filename,
          fileSize: fileSize,
          fallbackPath: pickedPath,
          // FilePicker fills `identifier` with the source content:// URI
          // on Android when the picker returns a MediaStore-backed file.
          // That URI carries the MediaStore id, which is the fastest and
          // most reliable resolve path.
          pickedIdentifier: pickedFile.identifier,
        );
        matchedAssetId = match?.assetId;
        matchedLocalPath = match?.localPath;
      }

      final newFile = CnestFile(
        id: fileId,
        filename: filename,
        sizeBytes: fileSize,
        createdAt: DateTime.now(),
        isUploaded: false,
        localPath: matchedLocalPath ?? (isLocalFile ? pickedPath : null),
        assetId: matchedAssetId,
        type: type,
        provider: 0,
        accountId: currentEmail,
      );

      await DatabaseService().addFile(newFile);

      // --- 5. ENCRYPT & UPLOAD ---
      String mainCloudFilename = '$fileId.cnest';
      Future<String?> mainUploadFuture;
      
      if (isVideo && fileStream != null) {
        final encryptedSize = EncryptionService.calculateEncryptedSize(fileSize);
        final encryptedStream = EncryptionService.encryptStream(fileStream);

        mainUploadFuture = CloudService().uploadEncryptedFile(
          filename: mainCloudFilename,
          type: type,
          originalName: filename,
          stream: encryptedStream,
          size: encryptedSize,
          bytes: null,
        );
      } else if (fileBytes != null) {
        final encryptedMainBytes = await EncryptionService.encryptFile(fileBytes);
        mainUploadFuture = CloudService().uploadEncryptedFile(
          filename: mainCloudFilename,
          type: type,
          originalName: filename,
          bytes: encryptedMainBytes,
        );
      } else {
        throw Exception("Invalid state");
      }

      Future<String?>? thumbUploadFuture;
      String? thumbCloudFilename;

      if (thumbnailBytes != null) {
        final encryptedThumbBytes = await EncryptionService.encryptFile(thumbnailBytes);
        thumbCloudFilename = '${fileId}_thumb.cnest';
        thumbUploadFuture = CloudService().uploadEncryptedFile(
          bytes: encryptedThumbBytes,
          filename: thumbCloudFilename,
          type: CnestFileType.image,
        );
      }

      final mainCloudId = await mainUploadFuture;
      final thumbCloudId = thumbUploadFuture != null ? await thumbUploadFuture : null;

      if (mainCloudId == null) throw Exception('Main upload failed');

      await DatabaseService().markAsUploaded(fileId, mainCloudId, thumbCloudId);
      DatabaseBackupService().scheduleBackup();

      // --- 6. CACHE MANAGEMENT ---
      try {
        // Only delete the source if it's a temp file from a cloud content provider.
        // Local gallery files are kept for local-first thumbnail loading.
        if (!isLocalFile) {
          final pickerFile = File(pickedPath);
          if (await pickerFile.exists()) {
            await pickerFile.delete();
          }
        }
      } catch (e) {
        debugPrint("Cleanup warning: $e");
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Secure Upload Complete')),
        );
      }

    } catch (e, s) {
      debugPrint('Upload failed: $e\n$s');
      // The DB row for `fileId` may have been inserted BEFORE the upload
      // started (step 4). If we don't roll it back here, the gallery
      // keeps a phantom entry for a file that never made it to the cloud
      // — the "cryptic red developer error" leaves a leftover row.
      // Roll back cleanly, then surface a friendly error sheet.
      final rollbackId = fileId;
      if (rollbackId != null) {
        try {
          await DatabaseService().deleteFile(rollbackId);
        } catch (rollbackErr) {
          debugPrint('Upload rollback failed: $rollbackErr');
        }
      }
      if (!mounted) return;
      await showCnestError(context, _mapUploadError(e));
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  CnestError _mapUploadError(Object e) {
    final msg = e.toString().toLowerCase();
    // Drive: 403 with "storageQuotaExceeded" in the JSON body.
    // Graph:  403/507 with "quotaLimitReached".
    if (msg.contains('storagequotaexceeded') ||
        msg.contains('quotalimitreached') ||
        msg.contains('quota exceeded')) {
      return const StorageFullError();
    }
    if (msg.contains('failed host lookup') ||
        msg.contains('network is unreachable') ||
        msg.contains('no address associated with hostname')) {
      return const OfflineError();
    }
    return UnexpectedError(code: 'UPLOAD', debugDetail: e.toString());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_isLoadingSession) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // Missing-cloud state is now handled by the reconnect screen (routed to
    // from splash, login, or _initSession's defensive catch). Home does not
    // render an inline error surface anymore.

    final cards = <Widget>[
      _DashboardCard(
        title: 'Photos & Videos',
        icon: 'images',
        color: cs.primary,
        showCardArt: true,
        onTap: () async {
          await Navigator.pushNamed(context, AppRoutes.gallery);
        },
      ),
      _DashboardCard(
        title: 'Documents',
        icon: 'fileText',
        color: cs.primary,
        onTap: () => Navigator.pushNamed(context, AppRoutes.documents),
      ),
      _DashboardCard(
        title: 'Audio',
        icon: 'musicNote',
        color: cs.primary,
        onTap: () => Navigator.pushNamed(context, AppRoutes.audio),
      ),
      _DashboardCard(
        title: 'Other Files',
        icon: 'folder',
        color: cs.primary,
        onTap: () => Navigator.pushNamed(context, AppRoutes.otherFiles),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const CiphernestLogo(fontSize: 22),
        actions: [
          const AccountSwitcher(),
          IconButton(
            icon: ThemeIcon('gear'),
            onPressed: () => Navigator.pushNamed(context, AppRoutes.settings),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your Vault', style: Theme.of(context).textTheme.headlineMedium),
            ListenableBuilder(
              listenable: AccountRegistry(),
              builder: (context, _) {
                final active = AccountRegistry().activeAccount;
                if (active == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Text(
                    '${active.email} · ${active.providerName}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurface.withAlpha(120)),
                  ),
                );
              },
            ),
            const SizedBox(height: 20),
            _VaultUsageCard(stats: _vaultStats),
            const SizedBox(height: 16),
            // Landscape: pack the four category cards into a 2x2 grid so the
            // user doesn't have to scroll past their full vertical stack on a
            // short canvas.
            OrientationBuilder(
              builder: (context, orientation) {
                if (orientation == Orientation.landscape) {
                  return Column(
                    children: [
                      Row(
                        children: [
                          Expanded(child: cards[0]),
                          const SizedBox(width: 16),
                          Expanded(child: cards[1]),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(child: cards[2]),
                          const SizedBox(width: 16),
                          Expanded(child: cards[3]),
                        ],
                      ),
                    ],
                  );
                }
                return Column(
                  children: [
                    cards[0],
                    const SizedBox(height: 16),
                    cards[1],
                    const SizedBox(height: 16),
                    cards[2],
                    const SizedBox(height: 16),
                    cards[3],
                  ],
                );
              },
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isUploading ? null : () => _showUploadSheet(context),
        backgroundColor: cs.primary,
        icon: _isUploading
          ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: cs.onPrimary, strokeWidth: 2))
          : ThemeIcon('plus', color: cs.onPrimary),
        label: Text(_isUploading ? 'Encrypting...' : 'Add File'),
      ),
    );
  }

  void _showUploadSheet(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: ThemeIcon('imageSquare', color: cs.primary),
              title: Text('Upload Photo or Video', style: TextStyle(color: cs.onSurface)),
              onTap: () {
                Navigator.pop(ctx);
                _handleUpload(category: _UploadCategory.media);
              },
            ),
            ListTile(
              leading: ThemeIcon('fileText', color: cs.primary),
              title: Text('Upload Document', style: TextStyle(color: cs.onSurface)),
              onTap: () {
                Navigator.pop(ctx);
                _handleUpload(category: _UploadCategory.document);
              },
            ),
            ListTile(
              leading: ThemeIcon('musicNote', color: cs.primary),
              title: Text('Upload Audio', style: TextStyle(color: cs.onSurface)),
              onTap: () {
                Navigator.pop(ctx);
                _handleUpload(category: _UploadCategory.audio);
              },
            ),
            ListTile(
              leading: ThemeIcon('folder', color: cs.primary),
              title: Text('Upload Other File', style: TextStyle(color: cs.onSurface)),
              subtitle: Text('zip, ipynb, py, anything',
                  style: TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 11)),
              onTap: () {
                Navigator.pop(ctx);
                _handleUpload(category: _UploadCategory.other);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _DashboardCard extends StatelessWidget {
  final String title;
  final String icon;
  final Color color;
  final VoidCallback onTap;
  /// If true, render the active theme pack's `cardArtAsset` behind the card
  /// content. Reserved for the Photos & Videos tile per the design system.
  final bool showCardArt;

  const _DashboardCard({
    required this.title,
    required this.icon,
    required this.color,
    required this.onTap,
    this.showCardArt = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = ThemeController().tokens;
    final radius = BorderRadius.circular(tokens.rCard);

    final foreground = Row(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(tokens.rIc),
          ),
          child: ThemeIcon(icon, color: color, size: 28),
        ),
        const SizedBox(width: 16),
        Text(title, style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600, fontSize: 18)),
        const Spacer(),
        ThemeIcon('caretRight', size: 16, color: cs.onSurface.withAlpha(120)),
      ],
    );

    return InkWell(
      onTap: onTap,
      borderRadius: radius,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: radius,
          border: Border.all(color: cs.outline),
        ),
        child: showCardArt
            ? Stack(
                children: [
                  // Theme pack's signature card art (binary digits, soil,
                  // skyline, UFO, newsprint, marble, code rain) tinted into
                  // the card surface at a low alpha so the icon + label stay
                  // readable.
                  Positioned.fill(
                    child: Opacity(
                      opacity: 0.22,
                      child: Image.asset(
                        tokens.cardArtAsset,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.all(tokens.pad),
                    child: foreground,
                  ),
                ],
              )
            : Padding(
                padding: EdgeInsets.all(tokens.pad),
                child: foreground,
              ),
      ),
    );
  }
}

class _VaultUsageCard extends StatelessWidget {
  final Map<String, int>? stats;
  const _VaultUsageCard({required this.stats});

  String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final images = stats?['images'] ?? 0;
    final docs = stats?['docs'] ?? 0;
    final audio = stats?['audio'] ?? 0;
    final other = stats?['other'] ?? 0;
    final trashBytes = stats?['trash_bytes'] ?? 0;
    final trashCount = stats?['trash_count'] ?? 0;
    // Live (non-trash) usage plus trash — the honest number for what's
    // actually costing the user's cloud quota right now. The Recycle Bin
    // sweeper doesn't touch Drive until the 30-day TTL, so a "just deleted
    // 6 MB" file is still on the wire.
    final live = images + docs + audio + other;
    final total = live + trashBytes;
    final count = stats?['total_count'] ?? 0;

    final tokens = ThemeController().tokens;
    final segments = <_UsageSegment>[
      _UsageSegment('Photos & Videos', images, cs.primary),
      _UsageSegment('Documents', docs, tokens.warning),
      _UsageSegment('Audio', audio, tokens.info),
      _UsageSegment('Other', other, tokens.fgMuted),
      if (trashBytes > 0)
        _UsageSegment('Recycle Bin', trashBytes, cs.onSurface.withAlpha(90)),
    ].where((s) => s.bytes > 0).toList();

    return Container(
      padding: EdgeInsets.all(tokens.pad),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(tokens.rCard),
        border: Border.all(color: cs.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ThemeIcon(
                'cloudCheck',
                color: cs.primary,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Vault usage',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                ),
              ),
              Text(
                stats == null ? '—' : _fmt(total),
                style: TextStyle(
                  color: cs.onSurface,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            stats == null
                ? 'Loading…'
                : trashCount > 0
                    ? '$count file${count == 1 ? '' : 's'} · '
                        '$trashCount in Recycle Bin'
                    : '$count file${count == 1 ? '' : 's'} encrypted on this account',
            style: TextStyle(
              color: cs.onSurface.withAlpha(140),
              fontSize: 12,
            ),
          ),
          if (segments.isNotEmpty) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 6,
                child: Row(
                  children: segments
                      .map(
                        (s) => Expanded(
                          flex: s.bytes,
                          child: Container(color: s.color),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: segments.map((s) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: s.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${s.label} · ${_fmt(s.bytes)}',
                      style: TextStyle(
                        color: cs.onSurface.withAlpha(180),
                        fontSize: 11,
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }
}

/// Result of resolving a picked file against the phone's gallery — used by
/// _handleUpload to tie manually-uploaded photos back to a MediaStore
/// asset so smart albums and local-first thumbnails work the same as they
/// do for auto-synced files.
class _GalleryAssetMatch {
  final String? assetId;
  final String? localPath;
  const _GalleryAssetMatch({this.assetId, this.localPath});
}

class _UsageSegment {
  final String label;
  final int bytes;
  final Color color;
  _UsageSegment(this.label, this.bytes, this.color);
}