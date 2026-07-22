import 'package:flutter/material.dart';
import '../../utils/byte_format.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/cloud/account_registry.dart';
import '../../../services/cloud/canary_retry.dart';
import '../../../services/cloud/cloud_account.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/cloud/google_drive_provider.dart';
import '../../../services/cloud/onedrive_provider.dart';
import '../../../services/cnest_errors.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/sync/sync_coordinator.dart';
import '../../../services/database_service.dart';
import '../../config/routes.dart';
import '../../config/theme_controller.dart';
import '../../models/file_model.dart';
import '../../widgets/friendly_error_sheet.dart';
import '../../widgets/theme_icon.dart';

/// Which flow entered the cloud picker. Each mode changes copy + how the
/// probe result is interpreted (existing files during signup are a warning,
/// but during restore they're expected).
enum CloudSelectionMode { signup, restore, addAnother, reconnect }

/// Route-argument container. Legacy callers can still pass a bare `true`
/// (interpreted as add-another for backward compatibility); new callers
/// should pass one of the [CloudSelectionArgs] constants.
class CloudSelectionArgs {
  const CloudSelectionArgs({this.mode = CloudSelectionMode.signup});
  final CloudSelectionMode mode;

  static const signup = CloudSelectionArgs();
  static const restore = CloudSelectionArgs(mode: CloudSelectionMode.restore);
  static const addAnother =
      CloudSelectionArgs(mode: CloudSelectionMode.addAnother);
  static const reconnect =
      CloudSelectionArgs(mode: CloudSelectionMode.reconnect);
}

class CloudSelectionScreen extends StatefulWidget {
  const CloudSelectionScreen({
    super.key,
    this.args = CloudSelectionArgs.signup,
    @Deprecated('Use args: CloudSelectionArgs.addAnother instead.')
    bool isAddAnother = false,
  }) : _legacyIsAddAnother = isAddAnother;

  final CloudSelectionArgs args;
  final bool _legacyIsAddAnother;

  CloudSelectionMode get _mode =>
      _legacyIsAddAnother ? CloudSelectionMode.addAnother : args.mode;

  @override
  State<CloudSelectionScreen> createState() => _CloudSelectionScreenState();
}

class _CloudSelectionScreenState extends State<CloudSelectionScreen> {
  bool _isLoading = false;
  String _statusMsg = '';

  CloudSelectionMode get _mode => widget._mode;

  // ---------------------------------------------------------------------------
  // Connect
  // ---------------------------------------------------------------------------

  Future<void> _connectProvider(int providerType) async {
    setState(() {
      _isLoading = true;
      _statusMsg = 'Authenticating...';
    });

    CloudAccount? newAccount;
    try {
      newAccount = providerType == CloudAccount.providerGoogle
          ? await GoogleDriveProvider.signInNewAccount()
          : providerType == CloudAccount.providerOneDrive
              ? await OneDriveProvider.signInNewAccount()
              : throw const _UnsupportedProviderException();

      if (newAccount == null) {
        // OAuth cancelled — silent return
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      await AccountRegistry().addAccount(newAccount);
      await AccountRegistry().setActive(newAccount.id);
      CloudService().reset();

      // Existing-vault probe. Only signup and restore care what's on the
      // remote cloud; addAnother/reconnect skip this step.
      var skipCanary = false;
      if (_mode == CloudSelectionMode.signup ||
          _mode == CloudSelectionMode.restore) {
        setState(() => _statusMsg = 'Checking your cloud...');
        final files = await CloudService().listCloudFiles();
        final hasExisting = files.isNotEmpty;

        if (_mode == CloudSelectionMode.signup && hasExisting) {
          final choice = await _promptExistingVaultOnSignup();
          if (choice == _ExistingVaultChoice.restoreInstead) {
            await AccountRegistry().removeAccount(newAccount.id);
            if (!mounted) return;
            Navigator.pushReplacementNamed(context, AppRoutes.restore);
            return;
          }
          if (choice == _ExistingVaultChoice.startOver) {
            // User accepted the orphaning; skip canary since it will fail
            // against another key.
            skipCanary = true;
          }
          if (choice == null) {
            await AccountRegistry().removeAccount(newAccount.id);
            if (mounted) setState(() => _isLoading = false);
            return;
          }
        }

        if (_mode == CloudSelectionMode.restore && !hasExisting) {
          final choice = await _promptEmptyVaultOnRestore();
          if (choice == _EmptyVaultChoice.tryDifferent) {
            await AccountRegistry().removeAccount(newAccount.id);
            if (mounted) setState(() => _isLoading = false);
            return;
          }
          if (choice == _EmptyVaultChoice.setUpAsNew) {
            skipCanary = true;
          }
          if (choice == null) {
            await AccountRegistry().removeAccount(newAccount.id);
            if (mounted) setState(() => _isLoading = false);
            return;
          }
        }
      }

      // Canary decrypts the first existing file. Confirms the vault key
      // matches this cloud. Skipped for the "orphan the old files" branches
      // above, and for reconnect/addAnother (which trust the caller).
      if (!skipCanary) {
        setState(() => _statusMsg = 'Verifying encryption keys...');
        final isValid = await canaryWithRetry();
        if (!isValid) {
          await AccountRegistry().removeAccount(newAccount.id);
          if (mounted) await _promptWrongPhrase();
          if (mounted) setState(() => _isLoading = false);
          return;
        }
      }

      DatabaseService().setCurrentAccount(newAccount.id);

      // Restore DB backup, if any (skip in add-another mode). Snapshots are
      // per-device since Stage 1 of multi-device sync: list them all, let
      // the user pick when more than one exists, and surface the
      // multi-device notice when another device's snapshot is present.
      if (_mode != CloudSelectionMode.addAnother) {
        setState(() => _statusMsg = 'Checking for backup...');
        final snapshots = await DatabaseBackupService().listSnapshots();
        if (snapshots.isNotEmpty) {
          final localImages =
              await DatabaseService().getFilesByType(CnestFileType.image);
          final localDocs =
              await DatabaseService().getFilesByType(CnestFileType.document);
          final localIsEmpty = localImages.isEmpty && localDocs.isEmpty;

          bool shouldRestore = localIsEmpty;
          if (!localIsEmpty && mounted) {
            shouldRestore = await _promptRestoreDbBackup() ?? false;
          }

          if (shouldRestore) {
            BackupSnapshot? pick = snapshots.first;
            if (snapshots.length > 1 && mounted) {
              pick = await _pickSnapshot(snapshots);
            }
            if (pick != null) {
              final restored = await DatabaseBackupService()
                  .restoreDatabase(cloudId: pick.cloudId);
              if (restored) {
                DatabaseService().setCurrentAccount(newAccount.id);
              }
            }
          }

          final hasForeign =
              snapshots.any((s) => !s.isLegacy && !s.isThisDevice);
          if (hasForeign && mounted) {
            await _showMultiDeviceNoticeOnce();
          }
        }
      }

      setState(() => _statusMsg = 'Loading your files...');
      // Op-log first (multi-device state), then blob reconcile (joins
      // op-created rows to their blobs by uuid stem).
      await SyncCoordinator().sync();
      final files = await CloudService().listCloudFiles();
      await DatabaseService().reconcile(files.cast<Map<String, dynamic>>());

      if (!mounted) return;
      if (_mode == CloudSelectionMode.addAnother) {
        Navigator.pop(context);
        return;
      }

      // Signup and restore flows drop the user through quick-settings once
      // per install (biometric + auto-sync opt-in). Reconnect skips it —
      // that user is already onboarded.
      if (_mode == CloudSelectionMode.signup ||
          _mode == CloudSelectionMode.restore) {
        final prefs = await SharedPreferences.getInstance();
        final shown = prefs.getBool('quick_settings_shown_v1') ?? false;
        if (!mounted) return;
        if (!shown) {
          Navigator.pushReplacementNamed(context, AppRoutes.quickSettings);
          return;
        }
      }

      Navigator.pushReplacementNamed(context, AppRoutes.home);
    } catch (e, s) {
      // Best-effort: roll back partial account registration if this failed
      // mid-flow. Ignore secondary errors during rollback.
      if (newAccount != null) {
        try {
          await AccountRegistry().removeAccount(newAccount.id);
        } catch (_) {}
      }
      if (!mounted) return;
      debugPrint('Cloud connect error: $e\n$s');
      final err = _mapConnectError(e);
      await showCnestError(context, err);
      if (mounted) setState(() => _isLoading = false);
    }
  }

  CnestError _mapConnectError(Object e) {
    if (e is _UnsupportedProviderException) {
      return const UnexpectedError(code: 'CS_UNSUP_PROVIDER');
    }
    final msg = e.toString().toLowerCase();
    // Storage-quota exceeded — Drive reports "storageQuotaExceeded" and
    // Graph reports "quotaLimitReached" in the JSON error body. Both flow
    // up as Exception messages containing those tokens. Not our bug to
    // fix, but we want a friendly sheet not a raw 403 dump.
    if (msg.contains('storagequotaexceeded') ||
        msg.contains('quotalimitreached') ||
        msg.contains('quota exceeded')) {
      return const StorageFullError();
    }
    // Only classify as offline when the OS explicitly reports no
    // connectivity. Generic 'socketexception' or 'timeout' can also come
    // from TLS handshake failures during OAuth against a reachable host
    // (see: OneDrive hang symptoms), which is emphatically NOT a Wi-Fi
    // problem — telling the user to check their Wi-Fi is misleading.
    if (msg.contains('failed host lookup') ||
        msg.contains('no address associated with hostname') ||
        msg.contains('network is unreachable') ||
        msg.contains('no route to host') ||
        msg.contains('connection refused')) {
      return const OfflineError();
    }
    if (msg.contains('token exchange failed') ||
        msg.contains('not authenticated') ||
        msg.contains('failed to fetch user info')) {
      return const AuthDeniedError(provider: 'Your provider');
    }
    return UnexpectedError(code: 'CS_CONN', debugDetail: e.toString());
  }

  // ---------------------------------------------------------------------------
  // Dialogs
  // ---------------------------------------------------------------------------

  Future<_ExistingVaultChoice?> _promptExistingVaultOnSignup() {
    final t = ThemeController().tokens;
    return showDialog<_ExistingVaultChoice>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('This account already has a CipherNest vault.'),
        content: const Text(
          "Good news: your files are safe. To read them, tap Restore and enter the recovery phrase from when you first signed up.\n\n"
          "If you've lost that phrase and want to start over on the same cloud, we can create a new empty vault here. Your old files won't be deleted. They will just be unreadable with this new password. You can clean them up later from Settings, Storage.",
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, _ExistingVaultChoice.startOver),
            style: TextButton.styleFrom(foregroundColor: t.danger),
            child: const Text('Start over on this cloud'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, _ExistingVaultChoice.restoreInstead),
            child: const Text('Restore instead'),
          ),
        ],
      ),
    );
  }

  Future<_EmptyVaultChoice?> _promptEmptyVaultOnRestore() {
    return showDialog<_EmptyVaultChoice>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('This account has no CipherNest files.'),
        content: const Text(
          "If you signed up on a different Google or Microsoft account, sign out and try that one. If this really is the right account, either the vault was deleted, or you never actually completed signup on this account.",
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, _EmptyVaultChoice.setUpAsNew),
            child: const Text("It's the right one, set up as new"),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, _EmptyVaultChoice.tryDifferent),
            child: const Text('Try a different account'),
          ),
        ],
      ),
    );
  }

  Future<void> _promptWrongPhrase() {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("That phrase doesn't match this vault."),
        content: const Text(
          "Either the recovery phrase is wrong, or this is a different cloud account than the one you signed up with.\n\n"
          "Double-check your phrase word by word. If you're sure it's right, try a different cloud account.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _promptRestoreDbBackup() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Backup found on cloud'),
        content: const Text(
          'A vault index backup was found on your cloud. Restore it? This replaces your current local index.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Skip'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
  }

  /// Snapshot picker for vaults with more than one per-device backup.
  /// Newest is listed first; returning null skips the restore.
  Future<BackupSnapshot?> _pickSnapshot(List<BackupSnapshot> snapshots) {
    String label(BackupSnapshot s) {
      if (s.isLegacy) return 'Older backup (previous app version)';
      return s.isThisDevice ? 'This device' : 'Another device';
    }

    String subtitle(BackupSnapshot s) {
      final when = s.modified;
      final date = when == null
          ? 'unknown date'
          : '${when.toLocal().year}-${when.toLocal().month.toString().padLeft(2, '0')}-${when.toLocal().day.toString().padLeft(2, '0')} '
              '${when.toLocal().hour.toString().padLeft(2, '0')}:${when.toLocal().minute.toString().padLeft(2, '0')}';
      return '$date · ${formatBytes(s.sizeBytes)}';
    }

    return showDialog<BackupSnapshot>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => SimpleDialog(
        title: const Text('Choose a backup to restore'),
        children: [
          for (final s in snapshots)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, s),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: ThemeIcon(
                  s.isThisDevice ? 'smartphone' : 'cloudArrowDown',
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                title: Text(label(s)),
                subtitle: Text(subtitle(s)),
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Skip restore'),
            ),
          ),
        ],
      ),
    );
  }

  /// One-time notice when another device's snapshot is detected on the
  /// vault. Stage 1 of multi-device sync: nothing is destroyed anymore,
  /// but each device still keeps its own view until the op-log ships.
  Future<void> _showMultiDeviceNoticeOnce() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('multi_device_notice_shown_v1') ?? false) return;
    await prefs.setBool('multi_device_notice_shown_v1', true);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Vault used on multiple devices'),
        content: const Text(
          'This vault is connected on another device too. Changes you make — '
          'organizing into folders, deleting, renaming — now sync across your '
          'devices automatically.\n\n'
          'If the same file is changed on two devices at once, deletions win '
          'and the other change is kept safe in the Recycle Bin. Nothing is '
          'ever silently lost.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _headline(),
                style: text.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                _subtext(),
                style: text.bodyMedium?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.72),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              _CloudOption(
                title: 'Google Drive',
                subtitle: 'Sign in with Google',
                icon: 'googleLogo',
                enabled: !_isLoading,
                onTap: () => _connectProvider(CloudAccount.providerGoogle),
              ),
              const SizedBox(height: 12),
              _CloudOption(
                title: 'OneDrive',
                subtitle: 'Sign in with Microsoft',
                icon: 'microsoftOutlookLogo',
                enabled: !_isLoading,
                onTap: () => _connectProvider(CloudAccount.providerOneDrive),
              ),
              const SizedBox(height: 12),
              _CloudOption(
                title: 'Dropbox',
                subtitle: 'Coming in v2',
                icon: 'cloud',
                enabled: false,
              ),
              const SizedBox(height: 12),
              _CloudOption(
                title: 'pCloud',
                subtitle: 'Coming in v2',
                icon: 'cloud',
                enabled: false,
              ),
              const SizedBox(height: 20),
              Text(
                'New here? Google Drive gives you 15 GB free. Most people start there.',
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.55),
                  fontSize: 12,
                ),
              ),
              if (_isLoading) ...[
                const SizedBox(height: 32),
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    _statusMsg,
                    style: text.bodySmall
                        ?.copyWith(color: cs.onSurface.withValues(alpha: 0.6)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _headline() {
    switch (_mode) {
      case CloudSelectionMode.addAnother:
        return 'Add another account';
      case CloudSelectionMode.restore:
        return 'Reconnect to your vault';
      case CloudSelectionMode.reconnect:
        return 'Reconnect your cloud';
      case CloudSelectionMode.signup:
        return 'Where should your files live?';
    }
  }

  String _subtext() {
    switch (_mode) {
      case CloudSelectionMode.addAnother:
        return "Add a second cloud under the same vault. Files stay encrypted end-to-end.";
      case CloudSelectionMode.restore:
        return "Pick the cloud where you originally set up CipherNest. We will decrypt your existing files with the phrase you just entered.";
      case CloudSelectionMode.reconnect:
        return "Pick the cloud you were signed into last time. Your files are safe there; we just need to re-link.";
      case CloudSelectionMode.signup:
        return "Your files stay encrypted end-to-end. Your cloud provider only ever sees scrambled data.";
    }
  }
}

class _CloudOption extends StatelessWidget {
  const _CloudOption({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.enabled,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final String icon;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(t.rCard),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: enabled
              ? cs.surface
              : cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(t.rCard),
          border: Border.all(
            color: enabled
                ? cs.primary.withValues(alpha: 0.4)
                : cs.outline.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          children: [
            ThemeIcon(
              icon,
              size: 26,
              color: enabled
                  ? cs.primary
                  : cs.onSurface.withValues(alpha: 0.4),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: enabled
                              ? cs.onSurface
                              : cs.onSurface.withValues(alpha: 0.6),
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.6),
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnsupportedProviderException implements Exception {
  const _UnsupportedProviderException();
}

enum _ExistingVaultChoice { restoreInstead, startOver }
enum _EmptyVaultChoice { tryDifferent, setUpAsNew }
