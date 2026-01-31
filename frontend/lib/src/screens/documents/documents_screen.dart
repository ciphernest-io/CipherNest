import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart'; // Launches native PDF reader
import 'package:path_provider/path_provider.dart'; // For temp storage
import 'package:intl/intl.dart'; // You might need to add intl to pubspec

import '../../config/theme.dart';
import '../../models/file_model.dart';
import '../../../services/database_service.dart';
import '../../../services/drive_service.dart';
import '../../../services/encryption_service.dart';

class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  late Future<List<CnestFile>> _filesFuture;
  String? _openingFileId; // Tracks which file is currently being decrypted

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _filesFuture = DatabaseService().getFilesByType(CnestFileType.document);
    });
  }

  // --- LOGIC: SECURE OPEN ---
  Future<void> _handleOpen(CnestFile file) async {
    if (_openingFileId != null) return; // Prevent double taps

    setState(() => _openingFileId = file.id);

    try {
      // 1. Get the path (Temp directory)
      // We use temp so the OS cleans it up later. Secure!
      final dir = await getTemporaryDirectory();
      final tempFile = File('${dir.path}/${file.filename}');

      // Optimization: Check if we already decrypted it recently
      if (await tempFile.exists()) {
        await OpenFile.open(tempFile.path);
        return;
      }

      // 2. Download & Decrypt
      if (file.cloudId == null) throw Exception("File not synced");
      
      final encryptedBytes = await DriveService.downloadFile(file.cloudId!);
      final decryptedBytes = await EncryptionService.decryptFile(encryptedBytes);

      // 3. Write to Disk & Launch
      await tempFile.writeAsBytes(decryptedBytes);
      
      final result = await OpenFile.open(tempFile.path);
      if (result.type != ResultType.done) {
        throw Exception(result.message);
      }

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open file: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _openingFileId = null);
    }
  }

  // --- LOGIC: DELETE ---
  Future<void> _handleDelete(CnestFile file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Document?'),
        content: Text('Permanently delete "${file.filename}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true), 
            child: const Text('Delete', style: TextStyle(color: Colors.red))
          ),
        ],
      ),
    );

    if (confirm == true) {
      if (file.cloudId != null) {
        await DriveService.deleteFile(file.cloudId!);
      }
      await DatabaseService().deleteFile(file.id);
      _refresh();
    }
  }

  // --- UI HELPER: FILE ICONS ---
  Widget _buildFileIcon(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    
    IconData icon;
    Color color;

    switch (ext) {
      case 'pdf':
        icon = Icons.picture_as_pdf;
        color = Colors.redAccent;
        break;
      case 'doc':
      case 'docx':
        icon = Icons.description;
        color = Colors.blueAccent;
        break;
      case 'xls':
      case 'xlsx':
      case 'csv':
        icon = Icons.table_chart;
        color = Colors.greenAccent;
        break;
      case 'ppt':
      case 'pptx':
        icon = Icons.slideshow;
        color = Colors.orangeAccent;
        break;
      case 'zip':
      case 'rar':
        icon = Icons.folder_zip;
        color = Colors.yellowAccent;
        break;
      default:
        icon = Icons.insert_drive_file;
        color = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: color, size: 28),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Documents'),
        actions: [
          IconButton(
            icon: const Icon(Icons.sync),
            onPressed: () async {
              // Quick manual sync trigger
              final cloudFiles = await DriveService.listCloudFiles();
              await DatabaseService().reconcile(cloudFiles);
              _refresh();
            },
          )
        ],
      ),
      body: FutureBuilder<List<CnestFile>>(
        future: _filesFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
             return const Center(child: CircularProgressIndicator());
          }
          
          final files = snapshot.data!;
          if (files.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.folder_open, size: 64, color: Colors.grey[800]),
                  const SizedBox(height: 16),
                  const Text('No documents found', style: TextStyle(color: Colors.grey)),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: files.length,
            separatorBuilder: (ctx, i) => const Divider(height: 1, color: Colors.white10),
            itemBuilder: (context, index) {
              final file = files[index];
              final isOpening = _openingFileId == file.id;

              return ListTile(
                contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                leading: _buildFileIcon(file.filename),
                title: Text(
                  file.filename,
                  style: const TextStyle(
                    color: Colors.white, 
                    fontWeight: FontWeight.w500
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${(file.sizeBytes / 1024).toStringAsFixed(0)} KB • ${DateFormat.yMMMd().format(file.createdAt)}',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                ),
                trailing: isOpening 
                  ? const SizedBox(
                      width: 24, height: 24, 
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)
                    )
                  : PopupMenuButton(
                      icon: const Icon(Icons.more_vert, color: Colors.grey),
                      itemBuilder: (ctx) => [
                        const PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(Icons.delete, color: Colors.red, size: 20),
                              SizedBox(width: 12),
                              Text('Delete', style: TextStyle(color: Colors.red)),
                            ],
                          ),
                        ),
                      ],
                      onSelected: (value) {
                        if (value == 'delete') _handleDelete(file);
                      },
                    ),
                onTap: () => _handleOpen(file),
              );
            },
          );
        },
      ),
    );
  }
}