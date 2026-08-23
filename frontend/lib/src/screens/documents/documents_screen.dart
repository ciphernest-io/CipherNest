import 'dart:io';
import '../../utils/byte_format.dart';
import 'package:flutter/material.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';
import 'package:open_file/open_file.dart'; // Launches native PDF reader
import 'package:path_provider/path_provider.dart'; // For temp storage
import 'package:intl/intl.dart'; // You might need to add intl to pubspec


import '../../models/file_model.dart';
import '../../../services/database_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/auto_sync_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/cnest_errors.dart';
import '../../../services/encryption_service.dart';
import '../../../services/notify.dart';
import '../../../services/sync_service.dart';
import '../../widgets/doc_thumbnail.dart';
import '../../widgets/friendly_error_sheet.dart';
import '../../widgets/file_actions.dart';
import '../share/share_dialog.dart';

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
    SyncService().syncNotifier.addListener(_onSyncComplete);
    DatabaseService().addListener(_onSyncComplete);
    _refresh();
  }

  @override
  void dispose() {
    SyncService().syncNotifier.removeListener(_onSyncComplete);
    DatabaseService().removeListener(_onSyncComplete);
    super.dispose();
  }

  void _onSyncComplete() {
    if (mounted) _refresh();
  }

  void _refresh() {
    setState(() {
      _filesFuture = DatabaseService().getFilesByType(CnestFileType.document);
    });
  }

  Future<void> _handleSync() async {
    await SyncService().syncNow(force: true);
  }

  // --- LOGIC: SECURE OPEN ---
  Future<void> _handleOpen(CnestFile file) async {
    if (_openingFileId != null) return; // Prevent double taps

    setState(() => _openingFileId = file.id);

    try {
      // A prior-key file (adopted after a start-over) can never decrypt
      // under this vault's phrase — say so instead of trying and dying.
      if (await DatabaseService().isPriorKeyFile(file.id)) {
        if (mounted) await showCnestError(context, const PriorKeyFileError());
        return;
      }
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
      
      final encryptedBytes = await CloudService().downloadFile(file.cloudId!);
      final decryptedBytes = await EncryptionService.decryptFile(encryptedBytes);

      // 3. Write to Disk & Launch
      await tempFile.writeAsBytes(decryptedBytes);
      
      final result = await OpenFile.open(tempFile.path);
      if (result.type != ResultType.done) {
        throw Exception(result.message);
      }

    } catch (e) {
      // Wrong-key MAC failure (prior-key leftover) gets plain language,
      // never the raw crypto exception.
      if (isCryptoAuthFailure(e)) {
        if (mounted) await showCnestError(context, const PriorKeyFileError());
      } else {
        Notify.error('Could not open file: $e');
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
        title: const Text('Move to Recycle Bin?'),
        content: Text(
          '"${file.filename}" will be hidden here. You can restore it from '
          'Recycle Bin for the next 30 days.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete',
                style: TextStyle(color: ThemeController().tokens.danger))
          ),
        ],
      ),
    );

    if (confirm == true) {
      // Soft-delete only. Recycle Bin sweeper handles the cloud-side purge
      // after 30 days; DatabaseService.deleteFile also wipes the local
      // cache and notifies listeners so this screen updates in-place.
      await DatabaseService().deleteFile(file.id);
      AutoSyncService.trackDeletion(file.filename, file.sizeBytes);
      DatabaseBackupService().scheduleBackup();
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Documents'),
        actions: [
          IconButton(
            icon: ThemeIcon('arrowsClockwise'),
            onPressed: _handleSync,
          )
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _handleSync,
        child: FutureBuilder<List<CnestFile>>(
          future: _filesFuture,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
               return const Center(child: CircularProgressIndicator());
            }

            final files = snapshot.data!;
            if (files.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  const SizedBox(height: 200),
                  Center(
                    child: Column(
                      children: [
                        ThemeIcon('folderOpen', size: 64, color: cs.onSurface.withAlpha(120)),
                        const SizedBox(height: 16),
                        Text('No documents found', style: TextStyle(color: cs.onSurface.withAlpha(120))),
                      ],
                    ),
                  ),
                ],
              );
            }

            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              itemCount: files.length,
              separatorBuilder: (ctx, i) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final file = files[index];
              final isOpening = _openingFileId == file.id;

              return Container(
                height: 90,
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(t.rInput),
                  border: Border.all(color: cs.outline),
                ),
                child: InkWell(
                  onTap: () => _handleOpen(file),
                  borderRadius: BorderRadius.circular(t.rInput),
                  child: Row(
                    children: [
                      // --- BIG THUMBNAIL (Left) ---
                      Container(
                        width: 80,
                        height: double.infinity,
                        decoration: BoxDecoration(
                          color: cs.surface,
                          borderRadius: BorderRadius.horizontal(
                              left: Radius.circular(t.rInput)),
                        ),
                        child: DocThumbnail(
                          key: ValueKey(file.id),
                          file: file,
                          borderRadius: BorderRadius.horizontal(
                              left: Radius.circular(t.rInput)),
                          iconSize: 36,
                        ),
                      ),

                      // --- TEXT INFO (Middle) ---
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                file.filename,
                                style: TextStyle(
                                  color: cs.onSurface,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 6),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Row(
                                  children: [
                                    // File Type Tag
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: cs.onSurface.withAlpha(25),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        file.filename.split('.').last.toUpperCase(),
                                        style: TextStyle(color: cs.onSurface.withAlpha(180), fontSize: 10, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      formatBytes(file.sizeBytes),
                                      style: TextStyle(color: cs.onSurface.withAlpha(120), fontSize: 12),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      '•  ${DateFormat.yMMMd().format(file.createdAt)}',
                                      style: TextStyle(color: cs.onSurface.withAlpha(120), fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // --- ACTIONS (Right) ---
                      if (isOpening)
                        Padding(
                          padding: const EdgeInsets.only(right: 24),
                          child: SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: cs.onSurface),
                          ),
                        )
                      else
                        PopupMenuButton(
                          icon: ThemeIcon('dotsThreeVertical', color: cs.onSurface.withAlpha(120)),
                          itemBuilder: (ctx) => [
                            const PopupMenuItem(
                              value: 'send',
                              child: Text('Send file'),
                            ),
                            const PopupMenuItem(
                              value: 'share',
                              child: Text('Share secure link'),
                            ),
                            const PopupMenuItem(
                              value: 'save',
                              child: Text('Save to device'),
                            ),
                            const PopupMenuItem(
                              value: 'rename',
                              child: Text('Rename'),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Row(
                                children: [
                                  ThemeIcon('trash', color: cs.error, size: 20),
                                  const SizedBox(width: 12),
                                  Text('Delete',
                                      style: TextStyle(color: cs.error)),
                                ],
                              ),
                            ),
                          ],
                          onSelected: (value) {
                            if (value == 'send') sendFilesPlain(context, [file]);
                            if (value == 'share') ShareDialog.show(context, file);
                            if (value == 'save') saveFileToDevice(context, file);
                            if (value == 'rename') {
                              promptRenameFile(context, file,
                                  onRenamed: (_) => _refresh());
                            }
                            if (value == 'delete') _handleDelete(file);
                          },
                        ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
      ),
    );
  }
}

