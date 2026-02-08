import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart'; // For thumbnails
import 'package:printing/printing.dart';
import 'package:file_picker/file_picker.dart'; // For documents
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:ui' as ui;

import '../../config/routes.dart';
import '../../config/theme.dart';
import '../../models/file_model.dart';
import '../../../services/database_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/image_picker_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isUploading = false;
  bool _isLoadingSession = true;
  String? _sessionError;

  @override
  void initState() {
    super.initState();
    _initSession();
  }

  Future<void> _initSession() async {
    // Reset state
    setState(() {
      _isLoadingSession = true;
      _sessionError = null;
    });

    try {
      // 1. Check if we already have an email (from login flow)
      String? email = CloudService().currentEmail;
      
      // 2. If not, try to restore it silently
      email ??= await CloudService().restoreSession();

      if (mounted) {
        if (email != null) {
          // Success: Tell DB who we are
          DatabaseService().setCurrentAccount(email);
          setState(() => _isLoadingSession = false);
        } else {
          // Failure: User needs to re-connect Drive
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

  /// NEW: Trigger manual login if session is lost
  Future<void> _handleReconnect() async {
    setState(() => _isLoadingSession = true);
    try {
      // Ensure CloudService has a public signIn method or exposes _googleSignIn
      await CloudService().signIn(); 
      await _initSession(); // Retry init after sign in
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
      // 1. Rasterize the PDF page
      await for (final page in Printing.raster(fileBytes, pages: [0], dpi: 72)) {
        final pdfImage = await page.toImage();

        // 2. Create a White Background (The "Paper")
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final paint = Paint()..color = Colors.white;
        
        // Fill the canvas with white
        canvas.drawRect(
          Rect.fromLTWH(0, 0, pdfImage.width.toDouble(), pdfImage.height.toDouble()),
          paint
        );

        // Draw the PDF image on top of the white
        canvas.drawImage(pdfImage, Offset.zero, Paint());

        // 3. Convert back to an Image
        final compositedImage = await recorder.endRecording().toImage(
          pdfImage.width, 
          pdfImage.height
        );

        // 4. Export to PNG (Intermediate Step - Unavoidable in Flutter)
        // But now it's OPAQUE (no transparency), so it's safe.
        final byteData = await compositedImage.toByteData(format: ui.ImageByteFormat.png);
        
        if (byteData == null) return null;
        var pngBytes = byteData.buffer.asUint8List();

        // 5. Convert to JPEG (Final Step)
        // This gives us the small file size we want, with a clean white background.
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
      debugPrint("PDF Thumbnail error: $e");
      return null;
    }
  }

  Future<void> _handleUpload(bool isImage) async {
    // Define these at the top so they are available everywhere
    Uint8List? fileBytes;
    String filename = ''; 
    Uint8List? thumbnailBytes;

    try {
      // --- STEP 1: PICK THE FILE ---
      if (isImage) {
        fileBytes = await ImagePickerService.pickImageAsBytes();
        filename = 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
      } else {
        // FIX: Restrict to common document formats
        FilePickerResult? result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt'], 
          withData: true,
        );
        
        if (result == null) return; // User cancelled
        
        fileBytes = result.files.first.bytes;
        filename = result.files.first.name;
      }

      // Safety check: Did we actually get a file?
      if (fileBytes == null) return;

      setState(() => _isUploading = true);

      // --- STEP 2: PROCESS (Generate Thumbnails) ---
      // Now that we have the file, we check its type
      
      if (isImage) {
        // A. Image Compression
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
        // B. PDF Rendering (Clean & Simple)
        try {
          // The generator handles the White Background AND JPEG compression internally
          // We use '!' because we know fileBytes is not null here
          thumbnailBytes = await _generatePdfThumbnail(fileBytes);
        } catch (e) {
          debugPrint("PDF thumbnail failed: $e");
        }
      }

      // --- STEP 3: DATABASE PREP ---
      final fileId = const Uuid().v4();
      final type = isImage ? CnestFileType.image : CnestFileType.document;
      final currentEmail = CloudService().currentEmail;

      if (currentEmail == null) throw Exception('No active Google Drive account found.');

      final newFile = CnestFile(
        id: fileId,
        filename: filename,
        sizeBytes: fileBytes.length,
        createdAt: DateTime.now(),
        isUploaded: false,
        type: type,
        provider: 0,
        accountId: currentEmail,
      );

      await DatabaseService().addFile(newFile);

      // --- STEP 4: ENCRYPTION ---
      final encryptedMainBytes = await EncryptionService.encryptFile(fileBytes);
      final mainCloudFilename = '$fileId.cnest';

      Uint8List? encryptedThumbBytes;
      String? thumbCloudFilename;
      
      if (thumbnailBytes != null) {
        encryptedThumbBytes = await EncryptionService.encryptFile(thumbnailBytes);
        thumbCloudFilename = '${fileId}_thumb.cnest';
      }

      // --- STEP 5: PARALLEL UPLOAD ---
      final uploadFutures = <Future<String?>>[
        CloudService().uploadEncryptedFile(
          bytes: encryptedMainBytes,
          filename: mainCloudFilename,
          isImage: isImage,
        ),
      ];

      if (encryptedThumbBytes != null && thumbCloudFilename != null) {
        uploadFutures.add(
          CloudService().uploadEncryptedFile(
            bytes: encryptedThumbBytes,
            filename: thumbCloudFilename,
            isImage: true, 
          )
        );
      } else {
        uploadFutures.add(Future.value(null));
      }

      final results = await Future.wait(uploadFutures);
      final mainCloudId = results[0];
      final thumbCloudId = results[1];

      if (mainCloudId == null) throw Exception('Main upload failed');

      // --- STEP 6: FINALIZE ---
      await DatabaseService().markAsUploaded(fileId, mainCloudId, thumbCloudId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Secure Upload Complete')),
        );
      }

    } catch (e) {
      debugPrint('Upload error: $e');
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
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // UPDATED: Show Reconnect UI if session failed
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
            Text(
              'Your Vault',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            if (CloudService().currentEmail != null)
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Text(
                  CloudService().currentEmail!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
                ),
              ),

            const SizedBox(height: 24),
            
            _DashboardCard(
              title: 'Photos & Videos',
              icon: Icons.photo_library,
              color: Colors.purpleAccent,
              onTap: () async {
                // Ensure we await result to refresh if needed (e.g. after deletion)
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

  // ... (Keep _showUploadSheet and _DashboardCard exactly as they were) ...
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
              leading: const Icon(Icons.image, color: Colors.purpleAccent),
              title: const Text('Upload Photo', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _handleUpload(true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.description, color: Colors.blueAccent),
              title: const Text('Upload Document', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _handleUpload(false);
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
            Text(
              title,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 18,
                  ),
            ),
            const Spacer(),
            const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}