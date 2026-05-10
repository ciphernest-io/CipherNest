import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart'; 
import 'package:printing/printing.dart';
import 'package:file_picker/file_picker.dart'; 
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:video_thumbnail/video_thumbnail.dart'; // NEW IMPORT

import '../../config/routes.dart';
import '../../widgets/account_switcher.dart';
import '../../widgets/ciphernest_logo.dart';

import '../../models/file_model.dart';
import '../../../services/database_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/cloud/account_registry.dart';
import '../../../services/encryption_service.dart';
import '../../../services/sync_service.dart';

enum _UploadCategory { media, document, audio }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _isUploading = false;
  bool _isLoadingSession = true;
  String? _sessionError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initSession();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SyncService().syncNow();
    }
  }

  Future<void> _initSession() async {
    setState(() {
      _isLoadingSession = true;
      _sessionError = null;
    });

    try {
      final active = AccountRegistry().activeAccount;
      String? email = active?.email;
      if (email == null) {
        email = await CloudService().restoreSession();
      }

      if (mounted) {
        if (active != null) {
          DatabaseService().setCurrentAccount(active.id);
          setState(() => _isLoadingSession = false);
          SyncService().syncNow();
        } else if (email != null) {
          // Legacy/edge case — no active account but a session exists
          setState(() => _isLoadingSession = false);
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

    Uint8List? fileBytes;
    Stream<List<int>>? fileStream;
    int? fileSize;
    String filename = '';
    Uint8List? thumbnailBytes;
    bool isVideo = false;
    String? pickedPath;

    try {
      // --- 1. UNIFIED PICKER (FilePicker Only) ---
      List<String> exts;
      if (isMedia) {
        exts = ['jpg', 'jpeg', 'png', 'heic', 'webp', 'mp4', 'mov', 'avi', 'mkv'];
      } else if (isAudio) {
        exts = ['mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg', 'opus', 'wma'];
      } else {
        exts = ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt'];
      }
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
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
          isImage: false,
          originalName: filename,
          stream: encryptedStream,
          size: encryptedSize,
          bytes: null,
        );
      } else if (fileBytes != null) {
        final encryptedMainBytes = await EncryptionService.encryptFile(fileBytes);
        mainUploadFuture = CloudService().uploadEncryptedFile(
          filename: mainCloudFilename,
          isImage: isMedia,
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
          isImage: true, 
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
              Icon(PhosphorIcons.cloudSlash(PhosphorIconsStyle.thin), size: 64, color: cs.onSurface.withAlpha(120)),
              const SizedBox(height: 16),
              Text(_sessionError!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _handleReconnect,
                icon: Icon(PhosphorIcons.signIn(PhosphorIconsStyle.thin)),
                label: const Text("Reconnect Google Drive"),
              )
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const CiphernestLogo(fontSize: 22),
        actions: [
          const AccountSwitcher(),
          IconButton(
            icon: Icon(PhosphorIcons.gear(PhosphorIconsStyle.thin)),
            onPressed: () => Navigator.pushNamed(context, AppRoutes.settings),
          ),
        ],
      ),
      body: Padding(
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
            const SizedBox(height: 24),
            _DashboardCard(
              title: 'Photos & Videos',
              icon: PhosphorIcons.images(PhosphorIconsStyle.thin),
              color: cs.primary,
              onTap: () async {
                await Navigator.pushNamed(context, AppRoutes.gallery);
              },
            ),
            const SizedBox(height: 16),
            _DashboardCard(
              title: 'Documents',
              icon: PhosphorIcons.fileText(PhosphorIconsStyle.thin),
              color: cs.primary,
              onTap: () => Navigator.pushNamed(context, AppRoutes.documents),
            ),
            const SizedBox(height: 16),
            _DashboardCard(
              title: 'Audio',
              icon: PhosphorIcons.musicNote(PhosphorIconsStyle.thin),
              color: cs.primary,
              onTap: () => Navigator.pushNamed(context, AppRoutes.audio),
            ),
            const SizedBox(height: 16),
            _DashboardCard(
              title: 'Other Files',
              icon: PhosphorIcons.folder(PhosphorIconsStyle.thin),
              color: cs.primary,
              onTap: () {},
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isUploading ? null : () => _showUploadSheet(context),
        backgroundColor: cs.primary,
        icon: _isUploading
          ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: cs.onPrimary, strokeWidth: 2))
          : Icon(PhosphorIcons.plus(PhosphorIconsStyle.thin), color: cs.onPrimary),
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
              leading: Icon(PhosphorIcons.imageSquare(PhosphorIconsStyle.thin), color: cs.primary),
              title: Text('Upload Photo or Video', style: TextStyle(color: cs.onSurface)),
              onTap: () {
                Navigator.pop(ctx);
                _handleUpload(category: _UploadCategory.media);
              },
            ),
            ListTile(
              leading: Icon(PhosphorIcons.fileText(PhosphorIconsStyle.thin), color: cs.primary),
              title: Text('Upload Document', style: TextStyle(color: cs.onSurface)),
              onTap: () {
                Navigator.pop(ctx);
                _handleUpload(category: _UploadCategory.document);
              },
            ),
            ListTile(
              leading: Icon(PhosphorIcons.musicNote(PhosphorIconsStyle.thin), color: cs.primary),
              title: Text('Upload Audio', style: TextStyle(color: cs.onSurface)),
              onTap: () {
                Navigator.pop(ctx);
                _handleUpload(category: _UploadCategory.audio);
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

  const _DashboardCard({
    required this.title,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cs.outline),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(width: 16),
            Text(title, style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600, fontSize: 18)),
            const Spacer(),
            Icon(PhosphorIcons.caretRight(PhosphorIconsStyle.thin), size: 16, color: cs.onSurface.withAlpha(120)),
          ],
        ),
      ),
    );
  }
}