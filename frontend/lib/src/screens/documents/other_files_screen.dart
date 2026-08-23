import 'dart:io';
import '../../utils/byte_format.dart';
import '../../utils/file_visuals.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';

import '../../models/file_model.dart';
import '../../../services/auto_sync_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/cnest_errors.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/database_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/notify.dart';
import '../../../services/sync_service.dart';
import '../../widgets/file_actions.dart';
import '../../widgets/friendly_error_sheet.dart';
import '../share/share_dialog.dart';

/// Tab for everything that isn't a photo/video, document (Office/PDF), or
/// audio — zips, ipynbs, py, csv, sqlite dumps, arbitrary binaries. Same
/// pattern as DocumentsScreen but the row is leaner (no PDF thumbnail) and
/// "Open" hands off to the system default for that extension.
class OtherFilesScreen extends StatefulWidget {
  const OtherFilesScreen({super.key});

  @override
  State<OtherFilesScreen> createState() => _OtherFilesScreenState();
}

class _OtherFilesScreenState extends State<OtherFilesScreen> {
  late Future<List<CnestFile>> _filesFuture;
  String? _openingFileId;

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
      _filesFuture = DatabaseService().getFilesByType(CnestFileType.other);
    });
  }

  Future<void> _handleSync() => SyncService().syncNow(force: true);

  Future<void> _handleOpen(CnestFile file) async {
    if (_openingFileId != null) return;
    setState(() => _openingFileId = file.id);
    try {
      // A prior-key file (adopted after a start-over) can never decrypt
      // under this vault's phrase — say so instead of trying and dying.
      if (await DatabaseService().isPriorKeyFile(file.id)) {
        if (mounted) await showCnestError(context, const PriorKeyFileError());
        return;
      }
      final dir = await getTemporaryDirectory();
      final tempFile = File('${dir.path}/${file.filename}');
      if (!await tempFile.exists()) {
        if (file.cloudId == null) throw Exception('File not synced');
        final encrypted = await CloudService().downloadFile(file.cloudId!);
        final decrypted = await EncryptionService.decryptFile(encrypted);
        await tempFile.writeAsBytes(decrypted);
      }
      final result = await OpenFile.open(tempFile.path);
      if (result.type != ResultType.done) throw Exception(result.message);
    } catch (e) {
      // A MAC failure here = wrong key for this blob (unflagged prior-key
      // leftover) — plain language, never the raw crypto exception.
      if (isCryptoAuthFailure(e)) {
        if (mounted) await showCnestError(context, const PriorKeyFileError());
      } else {
        Notify.error('Could not open file: $e');
      }
    } finally {
      if (mounted) setState(() => _openingFileId = null);
    }
  }

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
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Delete',
                  style:
                      TextStyle(color: ThemeController().tokens.danger))),
        ],
      ),
    );
    if (confirm != true) return;
    // Soft-delete only; Recycle Bin sweeper handles cloud purge.
    await DatabaseService().deleteFile(file.id);
    AutoSyncService.trackDeletion(file.filename, file.sizeBytes);
    DatabaseBackupService().scheduleBackup();
    _refresh();
  }

  String _humanSize(int bytes) => formatBytes(bytes);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Other Files'),
        actions: [
          IconButton(
            icon: ThemeIcon('arrowsClockwise'),
            onPressed: _handleSync,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _handleSync,
        child: FutureBuilder<List<CnestFile>>(
          future: _filesFuture,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final files = snap.data!;
            if (files.isEmpty) return _buildEmpty(cs);
            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              itemCount: files.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, i) => _buildRow(cs, files[i]),
            );
          },
        ),
      ),
    );
  }

  Widget _buildEmpty(ColorScheme cs) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 200),
        Center(
          child: Column(
            children: [
              ThemeIcon('archiveBox',
                  size: 64, color: cs.onSurface.withAlpha(120)),
              const SizedBox(height: 16),
              Text('No other files yet',
                  style: TextStyle(color: cs.onSurface.withAlpha(120))),
              const SizedBox(height: 6),
              Text('Upload zips, code, notebooks, anything.',
                  style:
                      TextStyle(color: cs.onSurface.withAlpha(90), fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRow(ColorScheme cs, CnestFile file) {
    final t = ThemeController().tokens;
    final isOpening = _openingFileId == file.id;
    final ext = file.filename.contains('.')
        ? file.filename.split('.').last.toUpperCase()
        : 'FILE';

    return Container(
      height: 88,
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
            Container(
              width: 64,
              height: double.infinity,
              alignment: Alignment.center,
              child: Builder(builder: (context) {
                final v =
                    fileVisual(file.filename, ThemeController().tokens);
                return ThemeIcon(v.icon,
                    color: v.color.withAlpha(204), size: 30);
              }),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      file.filename,
                      style: TextStyle(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w600,
                          fontSize: 15),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: cs.onSurface.withAlpha(25),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            ext,
                            style: TextStyle(
                                color: cs.onSurface.withAlpha(180),
                                fontSize: 10,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(_humanSize(file.sizeBytes),
                            style: TextStyle(
                                color: cs.onSurface.withAlpha(120),
                                fontSize: 12)),
                        const SizedBox(width: 8),
                        Text('•  ${DateFormat.yMMMd().format(file.createdAt)}',
                            style: TextStyle(
                                color: cs.onSurface.withAlpha(120),
                                fontSize: 12)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (isOpening)
              Padding(
                padding: const EdgeInsets.only(right: 20),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: cs.onSurface),
                ),
              )
            else
              PopupMenuButton<String>(
                icon: ThemeIcon('dotsThreeVertical',
                    color: cs.onSurface.withAlpha(120)),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'send', child: Text('Send file')),
                  const PopupMenuItem(
                      value: 'share', child: Text('Share secure link')),
                  const PopupMenuItem(
                      value: 'save', child: Text('Save to device')),
                  const PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(
                    value: 'delete',
                    child:
                        Text('Delete', style: TextStyle(color: cs.error)),
                  ),
                ],
                onSelected: (v) {
                  if (v == 'send') sendFilesPlain(context, [file]);
                  if (v == 'share') ShareDialog.show(context, file);
                  if (v == 'save') saveFileToDevice(context, file);
                  if (v == 'rename') {
                    promptRenameFile(context, file, onRenamed: (_) => _refresh());
                  }
                  if (v == 'delete') _handleDelete(file);
                },
              ),
          ],
        ),
      ),
    );
  }
}
