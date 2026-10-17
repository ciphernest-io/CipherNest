import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
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
import '../../../services/key_manager_service.dart';
import '../../../services/sync/segment_codec.dart';
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
enum CloudSelectionMode {
  signup,
  restore,
  addAnother,
  reconnect,

  /// A live local vault with an EMPTY account registry (the user
  /// disconnected every cloud). Connect runs the canary with the INSTALLED
  /// keys — no phrase entry, and never signup copy for a vault that
  /// already exists.
  attach,
}

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
  static const attach = CloudSelectionArgs(mode: CloudSelectionMode.attach);
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

  Future<void> _connectProvider(int providerType,
      {bool retriedAuth = false}) async {
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
      // Start-over bookkeeping: the pre-existing blobs are sealed under the
      // PREVIOUS vault key. Either we delete them now, or we adopt them
      // flagged prior_key so the UI never presents them as openable.
      var foreignVault = false;
      var purgeForeignBlobs = false;
      List<String> foreignCloudIds = const [];
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
            // Second, explicit choice: what happens to the old files. The
            // old copy promised cleanup "from Settings, Storage" while no
            // such control existed and the files presented as normal then
            // died with a raw crypto error on tap (MTR#1 B3/F5).
            final mains = files
                .where((f) =>
                    !((f['name'] as String? ?? '').endsWith('_thumb.cnest')))
                .length;
            if (!mounted) return;
            final cleanup = await _promptStartOverCleanup(mains);
            if (cleanup == null) {
              await AccountRegistry().removeAccount(newAccount.id);
              if (mounted) setState(() => _isLoading = false);
              return;
            }
            // Canary would fail against the old key by definition.
            skipCanary = true;
            foreignVault = true;
            purgeForeignBlobs = cleanup == _StartOverCleanup.deleteNow;
            foreignCloudIds = [
              for (final f in files)
                if (f['id'] is String) f['id'] as String
            ];
          }
          if (choice == null) {
            await AccountRegistry().removeAccount(newAccount.id);
            if (mounted) setState(() => _isLoading = false);
            return;
          }
        }

        if (_mode == CloudSelectionMode.restore && !hasExisting) {
          // F3: "vault exists" must mean more than blobs in vault/. A
          // completed signup that never uploaded still has op-log segments
          // in backup/log/ (and possibly an index snapshot); the old probe
          // read only vault/*.cnest and told those users their vault was
          // "deleted or signup was never completed".
          List<Map<String, dynamic>> logObjects = const [];
          var storageLevelVault = false;
          try {
            logObjects = await CloudService().listLogObjects();
            storageLevelVault = logObjects.isNotEmpty;
          } catch (_) {}
          if (!storageLevelVault) {
            try {
              storageLevelVault =
                  (await DatabaseBackupService().listSnapshots()).isNotEmpty;
            } catch (_) {}
          }

          if (storageLevelVault) {
            // Blob-less vault: the canary has nothing to decrypt (it passes
            // trivially on an empty listing), so ownership is proved
            // against a log segment instead — segments are HPKE-sealed to
            // the vault key exactly like file blobs, and the staged keys
            // are already in memory.
            setState(() => _statusMsg = 'Verifying encryption keys...');
            final owned = await _stagedKeysOpenAnyLogObject(logObjects);
            if (!owned) {
              await AccountRegistry().removeAccount(newAccount.id);
              if (!mounted) return;
              final exit = await _promptWrongPhrase(offerReEnter: true);
              await _handleWrongPhraseExit(exit);
              return;
            }
            skipCanary = true; // ownership proven
          } else {
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
      }

      // Canary decrypts the first existing file. Confirms the vault key
      // matches this cloud. Skipped for the "orphan the old files" branches
      // above, and for reconnect/addAnother (which trust the caller).
      if (!skipCanary) {
        setState(() => _statusMsg = 'Verifying encryption keys...');
        final isValid = await canaryWithRetry();
        if (!isValid) {
          await AccountRegistry().removeAccount(newAccount.id);
          if (!mounted) return;
          final exit = await _promptWrongPhrase(
              offerReEnter: _mode == CloudSelectionMode.restore);
          await _handleWrongPhraseExit(exit);
          return;
        }
      }

      // Ownership proven (canary, segment proof, or an explicit
      // use-this-account choice): persist the staged recovery NOW, before
      // any account/DB state lands. Until this line a wrong phrase costs
      // nothing — the old flow persisted the seed back at the password
      // screen and a wrong phrase was unrecoverable without a reinstall.
      if (_mode == CloudSelectionMode.restore &&
          KeyManagerService().hasStagedRecovery) {
        await KeyManagerService().commitStagedRecovery();
      }

      DatabaseService().setCurrentAccount(newAccount.id);

      if (purgeForeignBlobs) {
        await _purgeForeignVault(foreignCloudIds);
      }

      // Restore DB backup, if any (skip in add-another mode, and after a
      // start-over: those snapshots are sealed to the previous key and can
      // never be opened). Snapshots are per-device since Stage 1 of
      // multi-device sync: list them all, let the user pick when more than
      // one exists, and surface the multi-device notice when another
      // device's snapshot is present.
      if (_mode != CloudSelectionMode.addAnother && !foreignVault) {
        setState(() => _statusMsg = 'Checking for backup...');
        final snapshots = await DatabaseBackupService().listSnapshots();
        if (snapshots.isNotEmpty) {
          // includeHidden: an "is the vault empty?" check — a vault whose
          // only photos sit in hidden folders is NOT empty.
          final localImages = await DatabaseService()
              .getFilesByType(CnestFileType.image, includeHidden: true);
          final localDocs = await DatabaseService()
              .getFilesByType(CnestFileType.document, includeHidden: true);
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

      // Start-over: whatever pre-existing blobs survived (all of them on
      // the "keep" path, stray delete failures on the purge path) are now
      // adopted rows that can never decrypt — flag them so the UI is honest
      // and Settings > Storage can clean them up.
      if (foreignVault) {
        await DatabaseService().markPriorKeyByCloudIds(foreignCloudIds);
      }

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
      debugPrint('Cloud connect error: $e\n$s');
      // Revoked-grant self-heal (Google): after the user removes CipherNest
      // in Drive's "Manage Apps", GMS still serves a cached token for the
      // revoked grant — signIn() succeeds, then the first API call 401s.
      // Nuke the cached session (disconnect → fresh consent screen) and
      // retry ONCE. Safe here: the session that gets disconnected is the
      // one that just failed, and the account registration was rolled back.
      if (!retriedAuth &&
          providerType == CloudAccount.providerGoogle &&
          isAuthInvalidError(e)) {
        await GoogleDriveProvider.forceFreshConsent();
        if (!mounted) return;
        return _connectProvider(providerType, retriedAuth: true);
      }
      if (!mounted) return;
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
        msg.contains('failed to fetch user info') ||
        // Revoked/expired grant that survived the disconnect-and-retry:
        // an access problem, not a mystery (was CS_CONN).
        isAuthInvalidError(e)) {
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
        scrollable: true,
        title: const Text('This account already has a CipherNest vault.'),
        content: const Text(
          "Good news: your files are safe. To read them, tap Restore and enter the recovery phrase from when you first signed up.\n\n"
          "If you've lost that phrase, you can start over with a new empty vault on this same cloud. We'll ask what to do with the old files next.",
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

  /// The start-over follow-up: an explicit, counted decision about the old
  /// files. Null = cancel the whole start-over.
  Future<_StartOverCleanup?> _promptStartOverCleanup(int fileCount) {
    final t = ThemeController().tokens;
    final noun = fileCount == 1 ? 'file' : 'files';
    return showDialog<_StartOverCleanup>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('What about the old files?'),
        content: Text(
          "This account holds $fileCount encrypted $noun from the previous "
          "vault. Your new phrase can't open them.\n\n"
          "Delete them now to start clean, or keep them. Kept files stay in "
          "your cloud and show as locked in the app; you can remove them "
          "later in Settings under Storage.",
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, _StartOverCleanup.keepUnreadable),
            child: const Text('Keep them'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _StartOverCleanup.deleteNow),
            style: FilledButton.styleFrom(backgroundColor: t.danger),
            child: Text('Delete old $noun'),
          ),
        ],
      ),
    );
  }

  /// Deletes the previous vault's blobs plus its op-log segments and index
  /// snapshots (all sealed to the old key, all permanently unreadable).
  /// Best-effort per object: a straggler that survives gets adopted flagged
  /// prior_key by the post-reconcile mark, never as an openable file.
  Future<void> _purgeForeignVault(List<String> cloudIds) async {
    var done = 0;
    for (final id in cloudIds) {
      try {
        await CloudService().deleteFile(id);
      } catch (_) {}
      done++;
      if (done % 5 == 0 && mounted) {
        setState(() =>
            _statusMsg = 'Removing old files ($done/${cloudIds.length})...');
      }
    }
    try {
      for (final obj in await CloudService().listLogObjects()) {
        final id = obj['id'] as String?;
        if (id == null) continue;
        try {
          await CloudService().deleteFile(id);
        } catch (_) {}
      }
    } catch (_) {}
    try {
      for (final snap in await DatabaseBackupService().listSnapshots()) {
        try {
          await CloudService().deleteFile(snap.cloudId);
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<_EmptyVaultChoice?> _promptEmptyVaultOnRestore() {
    return showDialog<_EmptyVaultChoice>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('No CipherNest data on this account.'),
        content: const Text(
          "If your vault lives on a different Google or Microsoft account, connect that one instead.\n\n"
          "Or start fresh here: your phrase founds a new vault on this account. The same phrase can still restore your other vault elsewhere.",
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, _EmptyVaultChoice.tryDifferent),
            child: const Text('Try a different account'),
          ),
          // First-class action, not an error apology: creating a NEW
          // provider vault with an EXISTING phrase is a supported flow.
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, _EmptyVaultChoice.setUpAsNew),
            child: const Text('Use this account with my phrase'),
          ),
        ],
      ),
    );
  }

  /// Wrong key for this cloud's vault. Every exit is a real path forward —
  /// the old dialog's only action was "OK", which looped the user forever
  /// (the field report's restore dead end).
  Future<_WrongPhraseExit?> _promptWrongPhrase({required bool offerReEnter}) {
    return showDialog<_WrongPhraseExit>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text("That phrase doesn't match this vault."),
        content: const Text(
          "Either the recovery phrase is wrong, or this is a different cloud account than the one you signed up with.",
        ),
        actions: [
          if (offerReEnter)
            TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, _WrongPhraseExit.reEnterPhrase),
              child: const Text('Re-enter phrase'),
            ),
          if (offerReEnter)
            TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, _WrongPhraseExit.createNewVault),
              child: const Text('Create a new vault'),
            ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, _WrongPhraseExit.differentAccount),
            child: const Text('Try a different account'),
          ),
        ],
      ),
    );
  }

  /// Routes a [_WrongPhraseExit]. The staged keys survive only the
  /// "different account" path (same phrase, next cloud); the other exits
  /// leave the restore attempt entirely.
  Future<void> _handleWrongPhraseExit(_WrongPhraseExit? exit) async {
    switch (exit) {
      case _WrongPhraseExit.reEnterPhrase:
        KeyManagerService().discardStagedRecovery();
        if (mounted) {
          Navigator.pushReplacementNamed(context, AppRoutes.restore);
        }
      case _WrongPhraseExit.createNewVault:
        KeyManagerService().discardStagedRecovery();
        if (mounted) {
          Navigator.pushReplacementNamed(context, AppRoutes.masterPassword);
        }
      case _WrongPhraseExit.differentAccount:
      case null:
        if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Ownership probe for a blob-less vault: can the staged keys open any of
  /// the first few log objects? Snapshot-only vaults (no segments at all)
  /// pass without proof — the DB-restore step simply fails decryption on a
  /// wrong phrase and the vault attaches empty, a bounded downside.
  Future<bool> _stagedKeysOpenAnyLogObject(
      List<Map<String, dynamic>> objects) async {
    if (objects.isEmpty) return true;
    for (final obj in objects.take(3)) {
      final id = obj['id'] as String?;
      if (id == null) continue;
      try {
        final bytes = await CloudService().downloadFile(id);
        if (await SegmentCodec.tryOpen(bytes) != null) return true;
        if (await SegmentCodec.tryOpenSnapshot(bytes) != null) return true;
      } catch (_) {}
    }
    return false;
  }

  Future<bool?> _promptRestoreDbBackup() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        scrollable: true,
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
        scrollable: true,
        title: const Text('This vault syncs across installs'),
        content: const Text(
          'This vault has been set up more than once, either on another '
          'device or after reinstalling here. Changes you make, such as '
          'organizing into folders, deleting or renaming, now sync '
          'automatically wherever it is set up.\n\n'
          'If the same file is changed in two places at once, deletions win '
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
                textAlign: TextAlign.center,
                style: text.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                _subtext(),
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.72),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              _CloudOption(
                title: 'Google Drive',
                subtitle: 'Sign in with Google',
                logoAsset: 'assets/images/brands/google_drive.png',
                enabled: !_isLoading,
                onTap: () => _connectProvider(CloudAccount.providerGoogle),
              ),
              const SizedBox(height: 12),
              _CloudOption(
                title: 'OneDrive',
                subtitle: 'Sign in with Microsoft',
                logoAsset: 'assets/images/brands/onedrive.svg',
                enabled: !_isLoading,
                onTap: () => _connectProvider(CloudAccount.providerOneDrive),
              ),
              const SizedBox(height: 12),
              _CloudOption(
                title: 'Dropbox',
                subtitle: 'Coming in v2',
                logoAsset: 'assets/images/brands/dropbox.png',
                enabled: false,
              ),
              const SizedBox(height: 12),
              _CloudOption(
                title: 'pCloud',
                subtitle: 'Coming in v2',
                logoAsset: 'assets/images/brands/pcloud.png',
                enabled: false,
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
        return 'Choose your provider';
      case CloudSelectionMode.reconnect:
        return 'Choose your provider';
      case CloudSelectionMode.attach:
        return 'Connect a cloud to your vault';
      case CloudSelectionMode.signup:
        return 'Choose your provider';
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
      case CloudSelectionMode.attach:
        return "Your vault is on this device but no cloud is connected. Pick where its files should sync.";
      case CloudSelectionMode.signup:
        return "Pick where your encrypted files will live. You can add more accounts later, and one recovery phrase unlocks them all.";
    }
  }
}

class _CloudOption extends StatelessWidget {
  const _CloudOption({
    required this.title,
    required this.subtitle,
    required this.logoAsset,
    required this.enabled,
    this.onTap,
  });

  final String title;
  final String subtitle;

  /// The provider's official mark (assets/images/brands/, see its README).
  /// Drawn untinted per each vendor's brand guidelines; disabled rows only
  /// fade it.
  final String logoAsset;
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
            Opacity(
              opacity: enabled ? 1 : 0.4,
              child: SizedBox(
                width: 26,
                height: 26,
                child: logoAsset.endsWith('.svg')
                    ? SvgPicture.asset(logoAsset, fit: BoxFit.contain)
                    : Image.asset(logoAsset, fit: BoxFit.contain),
              ),
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

/// Start-over's follow-up decision about the previous vault's blobs.
enum _StartOverCleanup { deleteNow, keepUnreadable }

/// Exits from the wrong-phrase dialog — every one is a path forward.
enum _WrongPhraseExit { reEnterPhrase, createNewVault, differentAccount }
enum _EmptyVaultChoice { tryDifferent, setUpAsNew }
