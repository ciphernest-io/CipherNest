import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../../config/routes.dart';
import '../../../services/cloud/account_registry.dart';
import '../../../services/cloud/cloud_account.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/cloud/google_drive_provider.dart';
import '../../../services/cloud/onedrive_provider.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/database_service.dart';
import '../../models/file_model.dart';

class CloudSelectionScreen extends StatefulWidget {
  /// When true, navigation pops back instead of pushing home
  /// (used by "Add another account" flow from the home screen).
  final bool isAddAnother;

  const CloudSelectionScreen({super.key, this.isAddAnother = false});

  @override
  State<CloudSelectionScreen> createState() => _CloudSelectionScreenState();
}

class _CloudSelectionScreenState extends State<CloudSelectionScreen> {
  bool _isLoading = false;
  String _statusMsg = '';

  Future<void> _connectProvider(int providerType) async {
    setState(() {
      _isLoading = true;
      _statusMsg = 'Authenticating...';
    });

    try {
      // 1. OAuth flow → returns a CloudAccount with tokens
      CloudAccount? newAccount;
      if (providerType == CloudAccount.providerGoogle) {
        newAccount = await GoogleDriveProvider.signInNewAccount();
      } else if (providerType == CloudAccount.providerOneDrive) {
        newAccount = await OneDriveProvider.signInNewAccount();
      } else {
        throw Exception('Unsupported provider');
      }

      if (newAccount == null) {
        // User cancelled
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      // 2. Register the account and make it active
      await AccountRegistry().addAccount(newAccount);
      await AccountRegistry().setActive(newAccount.id);
      CloudService().reset(); // rebuild provider for the new active account

      // 3. Canary test
      setState(() => _statusMsg = 'Verifying encryption keys...');
      final isValid = await CloudService().canaryTest();
      if (!isValid) {
        if (mounted) {
          _showErrorDialog(
            'Verification Failed',
            'The files on this account cannot be unlocked with your Recovery Phrase.\n\nAre you using the wrong account or the wrong Phrase?',
          );
        }
        // Roll back the registration
        await AccountRegistry().removeAccount(newAccount.id);
        return;
      }

      // 4. Set DB current account
      DatabaseService().setCurrentAccount(newAccount.email);

      // 5. Restore DB backup if available (skip in add-another mode)
      if (!widget.isAddAnother) {
        setState(() => _statusMsg = 'Checking for backup...');
        final hasBackup = await DatabaseBackupService().hasCloudBackup();
        if (hasBackup) {
          final localImages =
              await DatabaseService().getFilesByType(CnestFileType.image);
          final localDocs =
              await DatabaseService().getFilesByType(CnestFileType.document);
          final localIsEmpty = localImages.isEmpty && localDocs.isEmpty;

          bool shouldRestore = localIsEmpty;
          if (!localIsEmpty && mounted) {
            shouldRestore = await _showRestoreDialog() ?? false;
          }

          if (shouldRestore) {
            final restored = await DatabaseBackupService().restoreDatabase();
            if (restored) {
              DatabaseService().setCurrentAccount(newAccount.email);
            }
          }
        }
      }

      // 6. Initial sync
      setState(() => _statusMsg = 'Loading your files...');
      final files = await CloudService().listCloudFiles();
      await DatabaseService().reconcile(files.cast<Map<String, dynamic>>());

      // 7. Navigate
      if (mounted) {
        if (widget.isAddAnother) {
          Navigator.pop(context);
        } else {
          Navigator.pushReplacementNamed(context, AppRoutes.home);
        }
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Skip')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Restore')),
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
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final headerText = widget.isAddAnother ? 'Add another account' : 'Choose your storage';
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isAddAnother ? 'Add Account' : 'Choose Storage'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(
              headerText,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 32),
            _CloudOption(
              title: 'Google Drive',
              subtitle: 'Sign in with Google',
              icon: PhosphorIcons.googleLogo(PhosphorIconsStyle.thin),
              enabled: !_isLoading,
              onTap: () => _connectProvider(CloudAccount.providerGoogle),
            ),
            const SizedBox(height: 16),
            _CloudOption(
              title: 'OneDrive',
              subtitle: 'Sign in with Microsoft',
              icon: PhosphorIcons.microsoftOutlookLogo(PhosphorIconsStyle.thin),
              enabled: !_isLoading,
              onTap: () => _connectProvider(CloudAccount.providerOneDrive),
            ),
            const SizedBox(height: 16),
            _CloudOption(
              title: 'Dropbox',
              subtitle: 'Coming soon',
              icon: PhosphorIcons.dropboxLogo(PhosphorIconsStyle.thin),
              enabled: false,
            ),
            if (_isLoading) ...[
              const SizedBox(height: 32),
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_statusMsg),
            ],
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
