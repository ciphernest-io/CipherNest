import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../../config/routes.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/database_service.dart';
import '../../models/file_model.dart';

class CloudSelectionScreen extends StatefulWidget {
  const CloudSelectionScreen({super.key});

  @override
  State<CloudSelectionScreen> createState() => _CloudSelectionScreenState();
}

class _CloudSelectionScreenState extends State<CloudSelectionScreen> {
  bool _isLoading = false;

  Future<void> _connectDrive() async {
    setState(() => _isLoading = true);
    try {
      // 1. Run Canary Test (Connects, Auth, Checks File Headers)
      final isValid = await CloudService().canaryTest();

      if (!isValid) {
        if (mounted) {
          _showErrorDialog(
            'Verification Failed', 
            'The files on this Drive Account cannot be unlocked with your Recovery Phrase.\n\nAre you using the wrong Google Account or the wrong Phrase?'
          );
        }
        return;
      }

      // 2. Set the Active Account in DB
      final email = CloudService().currentEmail;
      if (email != null) {
        DatabaseService().setCurrentAccount(email);
      }

      // 3. Check for and restore cloud DB backup
      final hasBackup = await DatabaseBackupService().hasCloudBackup();
      if (hasBackup) {
        final localImages = await DatabaseService().getFilesByType(CnestFileType.image);
        final localDocs = await DatabaseService().getFilesByType(CnestFileType.document);
        final localIsEmpty = localImages.isEmpty && localDocs.isEmpty;

        bool shouldRestore = localIsEmpty;
        if (!localIsEmpty && mounted) {
          shouldRestore = await _showRestoreDialog() ?? false;
        }

        if (shouldRestore) {
          final restored = await DatabaseBackupService().restoreDatabase();
          if (restored && email != null) {
            DatabaseService().setCurrentAccount(email);
          }
        }
      }

      // 4. Trigger Initial Sync Logic (Background)
      final files = await CloudService().listCloudFiles();
      await DatabaseService().reconcile(files.cast<Map<String, dynamic>>());

      // 4. Go Home
      if (mounted) {
        Navigator.pushReplacementNamed(context, AppRoutes.home);
      }
    } catch (e) {
      if (mounted) {
        _showErrorDialog('Connection Error', e.toString());
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<bool?> _showRestoreDialog() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Backup Found'),
        content: const Text(
          'A vault index backup was found on your cloud. '
          'Restore it? This replaces your current local index.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Skip'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(color: Colors.red)),
        content: Text(content),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Choose storage'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(
              'Link your cloud provider',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 32),

            _CloudOption(
              title: 'Google Drive',
              subtitle: _isLoading ? 'Connecting...' : 'Recommended',
              icon: PhosphorIcons.cloud(PhosphorIconsStyle.thin),
              enabled: !_isLoading,
              onTap: _connectDrive, // <--- Triggers the flow
            ),
            
            if (_isLoading) ...[
              const SizedBox(height: 32),
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              const Text('Verifying encryption keys...'),
            ],

            const SizedBox(height: 16),
            _CloudOption(
              title: 'OneDrive',
              subtitle: 'Coming soon',
              icon: PhosphorIcons.cloud(PhosphorIconsStyle.thin),
              enabled: false,
            ),
          ],
        ),
      ),
    );
  }
}

class _CloudOption extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;

  const _CloudOption({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.enabled,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: enabled ? cs.surface : cs.surface.withAlpha(128),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: enabled ? cs.primary.withAlpha(128) : cs.outline,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 28, color: enabled ? cs.primary : cs.onSurface.withAlpha(120)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.bodyLarge),
                  Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}