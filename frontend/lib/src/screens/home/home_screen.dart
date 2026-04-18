import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart'; 
import 'package:printing/printing.dart';
import 'package:file_picker/file_picker.dart'; 
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:video_thumbnail/video_thumbnail.dart'; // NEW IMPORT

import '../../config/routes.dart';
import '../../config/theme.dart';
import '../../models/file_model.dart';
import '../../../services/database_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/sync_service.dart';

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
      String? email = CloudService().currentEmail;
      email ??= await CloudService().restoreSession();

      if (mounted) {
        if (email != null) {
          DatabaseService().setCurrentAccount(email);
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
      await CloudService().signIn(); 
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

  Future<void> _handleUpload({required bool isMedia}) async {
    Uint8List? fileBytes;
    Stream<List<int>>? fileStream;
    int? fileSize;
    String filename = ''; 
    Uint8List? thumbnailBytes;
    bool isVideo = false;
    String? pickedPath; 

    try {
      // --- 1. UNIFIED PICKER (FilePicker Only) ---
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: isMedia 
            ? ['jpg', 'jpeg', 'png', 'heic', 'webp', 'mp4', 'mov', 'avi', 'mkv']
            : ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt'],
        withData: false, // Don't load into RAM
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
      final type = (isVideo || isMedia) ? CnestFileType.image : CnestFileType.document;
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
    if (_isLoadingSession) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_sessionError != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              Text(_sessionError!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _handleReconnect,
                icon: const Icon(Icons.login),
                label: const Text("Reconnect Google Drive"),
              )
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('CipherNest'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
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
            if (CloudService().currentEmail != null)
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Text(CloudService().currentEmail!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
              ),
            const SizedBox(height: 24),
            _DashboardCard(
              title: 'Photos & Videos',
              icon: Icons.photo_library,
              color: Colors.purpleAccent,
              onTap: () async {
                await Navigator.pushNamed(context, AppRoutes.gallery);
              },
            ),
            const SizedBox(height: 16),
            _DashboardCard(
              title: 'Documents',
              icon: Icons.description,
              color: Colors.blueAccent,
              onTap: () => Navigator.pushNamed(context, AppRoutes.documents),
            ),
            const SizedBox(height: 16),
            _DashboardCard(
              title: 'Other Files',
              icon: Icons.folder,
              color: Colors.tealAccent,
              onTap: () {},
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isUploading ? null : () => _showUploadSheet(context),
        backgroundColor: AppColors.primary,
        icon: _isUploading 
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) 
          : const Icon(Icons.add, color: Colors.white),
        label: Text(_isUploading ? 'Encrypting...' : 'Add File'),
      ),
    );
  }

  void _showUploadSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.perm_media, color: Colors.purpleAccent),
              title: const Text('Upload Photo or Video', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _handleUpload(isMedia: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.description, color: Colors.blueAccent),
              title: const Text('Upload Document', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _handleUpload(isMedia: false);
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.divider),
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
            const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}