import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../widgets/theme_icon.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart'; 
import 'package:printing/printing.dart';
import 'package:file_picker/file_picker.dart'; 
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:video_thumbnail/video_thumbnail.dart'; // NEW IMPORT

import '../../config/routes.dart';
import '../../config/theme_controller.dart';
import '../../widgets/account_switcher.dart';
import '../../widgets/ciphernest_logo.dart';

import '../../models/file_model.dart';
import '../../../services/database_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/cloud/account_registry.dart';
import '../../../services/encryption_service.dart';
import '../../../services/sync_service.dart';

enum _UploadCategory { media, document, audio, other }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _isUploading = false;
  bool _isLoadingSession = true;
  String? _sessionError;
  Map<String, int>? _vaultStats;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initSession();
    SyncService().syncNotifier.addListener(_refreshStats);
  }

  @override
  void dispose() {
    SyncService().syncNotifier.removeListener(_refreshStats);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SyncService().syncNow();
    }
  }

  Future<void> _refreshStats() async {
    final stats = await DatabaseService().getStorageStats();
    if (mounted) setState(() => _vaultStats = stats);
  }

  Future<void> _initSession() async {
    setState(() {
      _isLoadingSession = true;
      _sessionError = null;
    });

    try {
      final active = AccountRegistry().activeAccount;
      String? email = active?.email;
      email ??= await CloudService().restoreSession();

      if (mounted) {
        if (active != null) {
          DatabaseService().setCurrentAccount(active.id);
          setState(() => _isLoadingSession = false);
          _refreshStats();
          SyncService().syncNow();
        } else if (email != null) {
          // Legacy/edge case — no active account but a session exists
          setState(() => _isLoadingSession = false);
          _refreshStats();
          SyncService().syncNow();
        } else {
          setState(() {
            _isLoadingSession = false;
            _sessionError = "Session expired. Please reconnect.";
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingSession = false;
          _sessionError = "Connection failed: $e";
        });
      }
    }
  }

  Future<void> _handleReconnect() async {
    setState(() => _isLoadingSession = true);
    try {
      await Navigator.pushNamed(context, AppRoutes.cloudSelection);
      await _initSession();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingSession = false;
          _sessionError = "Login failed: $e";
        });
      }
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
      final fileId = const Uuid().v4();
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

      final newFile = CnestFile(
        id: fileId,
        filename: filename,
        sizeBytes: fileSize,
        createdAt: DateTime.now(),
        isUploaded: false,
        localPath: isLocalFile ? pickedPath : null,
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

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_isLoadingSession) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_sessionError != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ThemeIcon('cloudSlash', size: 64, color: cs.onSurface.withAlpha(120)),
              const SizedBox(height: 16),
              Text(_sessionError!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _handleReconnect,
                icon: ThemeIcon('signIn'),
                label: const Text("Reconnect Google Drive"),
              )
            ],
          ),
        ),
      );
    }

    final cards = <Widget>[
      _DashboardCard(
        title: 'Photos & Videos',
        icon: themeIconData('images'),
        color: cs.primary,
        showCardArt: true,
        onTap: () async {
          await Navigator.pushNamed(context, AppRoutes.gallery);
        },
      ),
      _DashboardCard(
        title: 'Documents',
        icon: themeIconData('fileText'),
        color: cs.primary,
        onTap: () => Navigator.pushNamed(context, AppRoutes.documents),
      ),
      _DashboardCard(
        title: 'Audio',
        icon: themeIconData('musicNote'),
        color: cs.primary,
        onTap: () => Navigator.pushNamed(context, AppRoutes.audio),
      ),
      _DashboardCard(
        title: 'Other Files',
        icon: themeIconData('folder'),
        color: cs.primary,
        onTap: () => Navigator.pushNamed(context, AppRoutes.otherFiles),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
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
  final IconData icon;
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
          child: Icon(icon, color: color, size: 28),
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
    final total = images + docs + audio + other;
    final count = stats?['total_count'] ?? 0;

    final segments = <_UsageSegment>[
      _UsageSegment('Photos & Videos', images, cs.primary),
      _UsageSegment('Documents', docs, Colors.amber.shade400),
      _UsageSegment('Audio', audio, Colors.tealAccent.shade400),
      _UsageSegment('Other', other, Colors.pinkAccent.shade100),
    ].where((s) => s.bytes > 0).toList();
    final tokens = ThemeController().tokens;

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
              Icon(
                themeIconData('cloudCheck'),
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

class _UsageSegment {
  final String label;
  final int bytes;
  final Color color;
  _UsageSegment(this.label, this.bytes, this.color);
}