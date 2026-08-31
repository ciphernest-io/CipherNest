import 'dart:io';
import 'package:flutter/material.dart';
import '../../utils/byte_format.dart';
import '../../widgets/theme_icon.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart'; // ENABLED
import '../../config/routes.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/cloud/account_registry.dart';
import '../../../services/cloud/cloud_account.dart';
import '../../../services/database_service.dart';
import '../../../services/upload_foreground_guard.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/cache_manager_service.dart';
import '../../../services/activity_center.dart';
import '../../../services/app_lock_service.dart';
import '../../../services/audio_player_service.dart';
import '../../../services/auto_sync_service.dart';
import '../../../services/auto_sync_worker.dart';
import '../../../services/notify.dart';
import '../../../services/biometric_unlock_service.dart';
import '../../../services/gallery_prefs.dart';
import '../../../services/key_manager_service.dart';
import '../../../services/metadata_migration_service.dart';
import '../../../services/vault_reset_service.dart';
import '../../models/file_model.dart';
import '../cloud_selection/cloud_selection_screen.dart'
    show CloudSelectionArgs;
import 'package:device_info_plus/device_info_plus.dart';
import '../../../services/sync/device_registry_service.dart';
import '../../../services/sync/sync_coordinator.dart';
import '../../../services/system_folders.dart';
import '../../../services/sync/vault_health_service.dart';
import '../../widgets/password_confirm_dialog.dart';
import 'backup_albums_screen.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../config/theme_packs.dart';
import '../../config/theme_controller.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _cacheSize = "Calculating...";

  /// Bytes in the temp dir that CipherNest did NOT write (OS thumbnail /
  /// engine caches). Null when zero — the subtitle stays clean.
  String? _systemCacheSize;
  double _cacheLimitGB = 0.5;    // The value the slider shows NOW
  double _originalLimitGB = 0.5; // The value saved on DISK
  
  bool _isLoading = true;
  bool get _hasChanges => _cacheLimitGB != _originalLimitGB;

  // Auto-Sync — persisted mode. The SwitchListTile at the top toggles the
  // whole feature on/off; the segmented picker below chooses between
  // background and foreground-only modes.
  AutoSyncMode _autoSyncMode = AutoSyncMode.off;
  bool get _autoSyncEnabled => _autoSyncMode != AutoSyncMode.off;
  String _lastSyncDisplay = 'Never';
  int _autoSyncIntervalMinutes = kAutoSyncIntervalDefaultMinutes;
  String _lastBgSyncDisplay = "hasn't run yet";
  // Null = unknown / not Android.
  bool? _batteryExempt;

  // Gallery
  bool _showFeatured = true;
  bool _showYearAgo = true;

  // Security
  int _autoLockMinutes = AppLockService.defaultMinutes;
  BiometricCapability _bioCapability = BiometricCapability.unavailable;
  bool _bioEnabled = false;
  String? _bioSubtitleOverride; // invalidation notice, shown once detected

  @override
  void initState() {
    super.initState();
    _loadStats();
    _loadPreferences(); // ENABLED
    _loadBiometricState();
    // Any cache mutation (invalidate on delete, LRU sweep on sync, wipe on
    // recycle-bin permanent-delete) now bumps CacheManagerService's
    // notifier. Without this listener the "Cache size" tile only re-scans
    // when the screen is remounted — the user's report was "delete from
    // Recycle Bin, back to Settings, cache still shows old size."
    CacheManagerService().addListener(_loadStats);
  }

  @override
  void dispose() {
    CacheManagerService().removeListener(_loadStats);
    super.dispose();
  }

  // --- NEW: PERSISTENCE LOGIC ---
  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = await AutoSyncScheduler.readMode();
    final interval = await AutoSyncScheduler.readInterval();
    final batteryExempt = await BatteryOptimization.isExempt();
    if (mounted) {
      final lastRunMs = prefs.getInt('auto_sync_last_run') ?? 0;
      final lastBgMs = prefs.getInt('auto_sync_last_bg_run') ?? 0;
      setState(() {
        final val = prefs.getDouble('cache_limit') ?? 0.5;
        _cacheLimitGB = val;
        _originalLimitGB = val;
        _autoSyncMode = mode;
        _autoSyncIntervalMinutes = interval.inMinutes;
        _showFeatured = prefs.getBool('gallery_show_featured') ?? true;
        _showYearAgo = prefs.getBool('gallery_show_year_ago') ?? true;
        _autoLockMinutes = prefs.getInt(AppLockService.prefsKeyMinutes) ??
            AppLockService.defaultMinutes;
        if (lastRunMs > 0) {
          final dt = DateTime.fromMillisecondsSinceEpoch(lastRunMs);
          _lastSyncDisplay = '${dt.month}/${dt.day} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
        }
        if (lastBgMs > 0) {
          final dt = DateTime.fromMillisecondsSinceEpoch(lastBgMs);
          _lastBgSyncDisplay = '${dt.month}/${dt.day} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
        }
        _batteryExempt = batteryExempt;
      });
    }
  }

  Future<void> _loadBiometricState() async {
    final svc = BiometricUnlockService();
    final capability = await svc.capability();
    var enabled = await svc.isEnabled();
    String? notice;
    if (enabled) {
      // Detect enrollment-change invalidation here too, so the toggle never
      // lies: wipe the dead wrap and render off with an explanation.
      final armed = await svc.checkArmed();
      if (armed != BiometricArmedState.armed) {
        await KeyManagerService().disableBiometric();
        enabled = false;
        notice = 'Device security settings changed — re-enable to continue '
            'using fingerprint unlock.';
      }
    }
    if (!mounted) return;
    setState(() {
      _bioCapability = capability;
      _bioEnabled = enabled;
      _bioSubtitleOverride = notice;
    });
  }

  bool _vaultHealthScanning = false;

  /// Bumped after a prior-key cleanup so the FutureBuilder tile re-queries.
  int _priorKeyRefresh = 0;
  VaultHealthReport? _vaultHealth;

  String _vaultHealthSubtitle(ColorScheme cs) {
    final r = _vaultHealth;
    if (r == null) return 'Check for orphaned or missing files';
    if (r.isHealthy) return 'Everything looks good';
    final parts = <String>[
      if (r.orphanBlobIds.isNotEmpty) '${r.orphanBlobIds.length} orphaned',
      if (r.missingBlobFileIds.isNotEmpty)
        '${r.missingBlobFileIds.length} missing',
      if (r.unreadableSegments > 0) '${r.unreadableSegments} unreadable',
      if (r.clockSkewDetected) 'clock check',
    ];
    return parts.join(' · ');
  }

  Future<void> _openDevices() async {
    final account = AccountRegistry().activeAccount;
    if (account == null) return;
    final devices =
        await DeviceRegistryService().listDevices(accountId: account.id);
    final currentName = await DeviceRegistryService().deviceName();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Uncapped height: the rename field's keyboard inset must not push
      // the device list past a 9/16-screen sheet.
      isScrollControlled: true,
      builder: (ctx) => _DevicesSheet(
        devices: devices,
        currentName: currentName,
        onRename: (name) async {
          await DeviceRegistryService().setDeviceName(name);
          await _renameDeviceFolder(name);
          await SyncCoordinator().pushOnly();
        },
      ),
    );
  }

  /// Keeps the Phone Backup device folder's display name in step with the
  /// registry name. Best-effort: the folder only exists once auto-sync has
  /// run, and a rename is an ordinary LWW renameFolder op.
  Future<void> _renameDeviceFolder(String name) async {
    final account = AccountRegistry().activeAccount;
    if (account == null) return;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final key = SystemFolders.deviceKey(
          info.manufacturer.trim(), info.model.trim());
      final folderId = SystemFolders.deviceId(account.id, key);
      final row = await DatabaseService().getFolderById(folderId);
      if (row == null || row.isDeleted) return;
      await DatabaseService().renameFolder(folderId, name);
    } catch (_) {
      // The registry name is the source of truth; the folder catches up on
      // the next rename or stays as-is.
    }
  }

  Future<void> _runVaultHealthScan() async {
    final account = AccountRegistry().activeAccount;
    if (account == null) return;
    setState(() => _vaultHealthScanning = true);
    VaultHealthReport? report;
    try {
      report = await VaultHealthService().scan(accountId: account.id);
    } catch (e) {
      Notify.error('Vault Health scan failed: $e');
    }
    if (!mounted) return;
    setState(() {
      _vaultHealthScanning = false;
      _vaultHealth = report;
    });
    if (report == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _VaultHealthSheet(report: report!),
    );
  }

  /// Bulk-removes prior-key files: cloud blobs first (main must go, or the
  /// row stays so the next reconcile can't silently re-adopt an unflagged
  /// legacy-name blob), then the op-less local row. No purgeFile op — these
  /// rows never had a createFile op, so there is nothing to converge.
  Future<void> _cleanupPriorKeyFiles(List<CnestFile> rows) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
            'Delete ${rows.length} locked file${rows.length == 1 ? '' : 's'}?'),
        content: const Text(
          'These files were encrypted under a previous recovery phrase and '
          'can never be opened with this vault. This deletes them from your '
          'cloud permanently.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete forever',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    Future<void> deleteBlobTolerant(String id) async {
      try {
        await CloudService().deleteFile(id);
      } catch (e) {
        final m = e.toString().toLowerCase();
        // Already gone = success for our purposes.
        if (!m.contains('404') && !m.contains('not found') &&
            !m.contains('notfound') && !m.contains('itemnotfound')) {
          rethrow;
        }
      }
    }

    final task = ActivityCenter().start(
        kind: ActivityKind.binOp,
        label: 'Removing 0/${rows.length}…',
        total: rows.length);
    var ok = 0;
    var done = 0;
    for (final f in rows) {
      try {
        if (f.cloudId != null) await deleteBlobTolerant(f.cloudId!);
        if (f.thumbnailCloudId != null) {
          try {
            await deleteBlobTolerant(f.thumbnailCloudId!);
          } catch (_) {}
        }
        await DatabaseService().hardDeletePriorKeyRow(f.id);
        ok++;
      } catch (_) {
        // Row kept: blob still in the cloud, tile stays until it succeeds.
      }
      done++;
      task.update(done, label: 'Removing $done/${rows.length}…');
    }
    final failed = rows.length - ok;
    if (failed > 0) {
      task.fail('$ok removed · $failed failed, try again later');
    } else {
      task.complete('$ok old file${ok == 1 ? '' : 's'} removed');
    }
    if (mounted) setState(() => _priorKeyRefresh++);
  }

  Future<void> _runMetadataMigration() async {
    final count = await MetadataMigrationService().scanLegacyCount();
    if (!mounted) return;
    if (count == 0) {
      Notify.info('All cloud metadata is already encrypted');
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Encrypt cloud metadata?'),
        content: Text(
          '$count file${count == 1 ? '' : 's'} in your cloud vault still '
          'carry a readable filename in their metadata. This rewrites the '
          'metadata only — no file content is re-uploaded. You can '
          'interrupt and re-run anytime.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Encrypt')),
        ],
      ),
    );
    if (go != true) return;
    final result = await MetadataMigrationService().run();
    if (result.failed == 0) {
      Notify.info('Cloud metadata encrypted (${result.done} files)');
    } else {
      Notify.error(
          'Encrypted ${result.done}, ${result.failed} failed — re-run to retry');
    }
  }

  Future<void> _toggleBiometric(bool v) async {
    if (!v) {
      await KeyManagerService().disableBiometric();
      if (mounted) {
        setState(() {
          _bioEnabled = false;
          _bioSubtitleOverride = null;
        });
      }
      return;
    }
    final password = await showPasswordConfirmDialog(context);
    if (password == null || !mounted) return;
    try {
      final ok = await KeyManagerService().enableBiometric(password);
      if (!mounted) return;
      if (!ok) {
        Notify.error('Incorrect password');
        return;
      }
      setState(() {
        _bioEnabled = true;
        _bioSubtitleOverride = null;
      });
    } on BiometricUnlockException catch (e) {
      if (e.code == BiometricUnlockError.userCanceled) return;
      Notify.error('Could not enable fingerprint unlock (${e.code.name})');
    }
  }

  Future<void> _savePreferences() async {
    setState(() => _isLoading = true); // Show loading feedback

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('cache_limit', _cacheLimitGB);

    // Run the cleaner immediately
    await CacheManagerService().enforceCacheLimit();

    if (mounted) {
      setState(() {
        _originalLimitGB = _cacheLimitGB; // Sync them, so button disables
        _isLoading = false;
      });
      Notify.info('Cache limit saved & applied');
      _loadStats(); // Reload stats to show freed space
    }
  }

  Future<void> _loadStats() async {
    // Two honest figures instead of one misleading one. CipherNest writes
    // its cache artifacts flat into the temp-dir root (thumb_*, *_decrypted,
    // video_*.plain*, picker copies under file_picker/). Everything else in
    // there — subdirectories like Glide's image_manager_disk_cache/ or
    // Flutter's shader cache — is written by Android/engine plumbing that
    // every app carries and that we don't control. Counting it as "our"
    // cache made the figure creep for no user-visible reason.
    final tempDir = await getTemporaryDirectory();
    int appBytes = 0;
    int systemBytes = 0;
    try {
      if (await tempDir.exists()) {
        final rootPath = tempDir.path;
        final pickerPrefix = '$rootPath${Platform.pathSeparator}file_picker';
        await for (var file
            in tempDir.list(recursive: true, followLinks: false)) {
          if (file is! File) continue;
          final inRoot = file.parent.path == rootPath;
          final isPickerCopy = file.path.startsWith(pickerPrefix);
          if (inRoot || isPickerCopy) {
            appBytes += await file.length();
          } else {
            systemBytes += await file.length();
          }
        }
      }
    } catch (e) {
      debugPrint("Cache error: $e");
    }

    if (mounted) {
      setState(() {
        _cacheSize = _formatBytes(appBytes);
        _systemCacheSize = systemBytes > 0 ? _formatBytes(systemBytes) : null;
        _isLoading = false;
      });
    }
  }

  static String _autoLockLabel(int minutes) {
    if (minutes <= 0) return 'Never — vault stays unlocked';
    if (minutes == 1) return 'Lock after 1 minute of inactivity';
    return 'Lock after $minutes minutes of inactivity';
  }

  Future<void> _pickAutoLock() async {
    const options = [1, 5, 15, 30, 0]; // 0 = never
    final cs = Theme.of(context).colorScheme;
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        // shrinkWrap list: sizes like the Column when the tiles fit, scrolls
        // inside the sheet's 9/16 cap when they don't (landscape).
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            for (final m in options)
              ListTile(
                title: Text(
                    m <= 0 ? 'Never' : (m == 1 ? '1 minute' : '$m minutes')),
                trailing: m == _autoLockMinutes
                    ? ThemeIcon('check', color: cs.primary)
                    : null,
                onTap: () => Navigator.pop(ctx, m),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await AppLockService().setTimeoutMinutes(picked);
    if (mounted) setState(() => _autoLockMinutes = picked);
  }

  String _formatBytes(int bytes) => formatBytes(bytes);

  /// Size-unit convention picker. 1000 matches Samsung Gallery / Android's
  /// own UI; 1024 keeps binary semantics for people who want them.
  Future<void> _pickSizeUnits() async {
    final cs = Theme.of(context).colorScheme;
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (base, label) in const [
              (1000, 'Match system — 1,000 bytes per KB'),
              (1024, 'Binary — 1,024 bytes per KB'),
            ])
              ListTile(
                title: Text(label),
                trailing: base == ByteFormat.base
                    ? ThemeIcon('check', color: cs.primary)
                    : null,
                onTap: () => Navigator.pop(ctx, base),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked == ByteFormat.base) return;
    await ByteFormat.setBase(picked);
    if (!mounted) return;
    setState(() {});
    // Reformat the cached size string with the new base.
    _loadStats();
  }

  Future<void> _clearCache() async {
    final tempDir = await getTemporaryDirectory();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
      await tempDir.create();
    }
    if (mounted) {
      Notify.info('Cache cleared');
      _loadStats();
    }
  }

  /// Long-press diagnostic on the cache tile: itemizes exactly which files
  /// make up the CipherNest figure (temp root + picker copies), largest
  /// first. Turns "the cache grew" into "this file appeared".
  Future<void> _showCacheContents() async {
    final tempDir = await getTemporaryDirectory();
    final entries = <(String, int)>[];
    try {
      if (await tempDir.exists()) {
        final rootPath = tempDir.path;
        final pickerPrefix = '$rootPath${Platform.pathSeparator}file_picker';
        await for (var f
            in tempDir.list(recursive: true, followLinks: false)) {
          if (f is! File) continue;
          if (f.parent.path != rootPath && !f.path.startsWith(pickerPrefix)) {
            continue;
          }
          entries.add((
            f.path.substring(rootPath.length + 1),
            await f.length(),
          ));
        }
      }
    } catch (e) {
      debugPrint('Cache listing error: $e');
    }
    entries.sort((a, b) => b.$2.compareTo(a.$2));
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: entries.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'CipherNest cache is empty.',
                  style: TextStyle(color: cs.onSurface.withAlpha(170)),
                ),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: entries.length,
                itemBuilder: (ctx, i) => ListTile(
                  dense: true,
                  title: Text(
                    entries[i].$1,
                    style: TextStyle(color: cs.onSurface, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    formatBytes(entries[i].$2),
                    style: TextStyle(
                        color: cs.onSurface.withAlpha(170), fontSize: 13),
                  ),
                ),
              ),
      ),
    );
  }

  Future<void> _handleBackup() async {
    setState(() => _isLoading = true);
    try {
      // backupDatabase never throws — it returns whether the snapshot
      // landed. Failure toasts itself via the quiet task; a manual tap
      // still deserves a positive receipt on success.
      final ok = await DatabaseBackupService().backupDatabase();
      if (ok) Notify.info('Vault index backed up');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _toggleAutoSync(bool enabled) async {
    if (enabled) {
      // Request permissions first
      final status = await [Permission.photos, Permission.videos].request();
      final allGranted = status.values.every(
        (s) => s.isGranted || s.isLimited,
      );
      if (!allGranted) {
        Notify.error('Media permissions are required for auto-sync');
        return;
      }
      // Notifications: non-fatal if denied — the upload foreground service
      // and the background worker still run, their notifications just stay
      // hidden (Android 13+ suppresses them without this grant).
      await Permission.notification.request();
    }

    // Default to `background` when the user first enables the feature — it
    // matches what Quick Settings sets and matches "always on" expectations.
    // The mode picker below lets them switch to foreground-only later.
    final mode = enabled ? AutoSyncMode.background : AutoSyncMode.off;
    await AutoSyncScheduler.writeMode(mode);
    if (enabled) {
      final prefs = await SharedPreferences.getInstance();
      // Set watermark to NOW — only photos taken after this moment auto-sync.
      // Per-album backfill (or Migration) pulls in older photos on demand.
      await prefs.setInt(
        'auto_sync_watermark',
        DateTime.now().millisecondsSinceEpoch,
      );
    }
    if (mounted) setState(() => _autoSyncMode = mode);
    // Which albums? All vs a checklist, plus the include-existing shortcut.
    if (enabled && mounted) await showBackupAlbumChoiceSheet(context);
  }

  /// Switches between [AutoSyncMode.background] and [AutoSyncMode.foregroundOnly]
  /// without changing whether auto-sync is enabled overall. Called from the
  /// segmented picker that appears under the top-level toggle.
  Future<void> _setAutoSyncMode(AutoSyncMode mode) async {
    if (mode == _autoSyncMode || mode == AutoSyncMode.off) return;
    await AutoSyncScheduler.writeMode(mode);
    if (mounted) setState(() => _autoSyncMode = mode);
  }

  static String _autoSyncIntervalLabel(int minutes) {
    if (minutes < 60) return 'Every $minutes minutes';
    if (minutes == 60) return 'Every hour';
    if (minutes < 1440) return 'Every ${minutes ~/ 60} hours';
    return 'Once a day';
  }

  Future<void> _pickAutoSyncInterval() async {
    final cs = Theme.of(context).colorScheme;
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        // shrinkWrap list: sizes like the Column when the tiles fit, scrolls
        // inside the sheet's 9/16 cap when they don't (landscape).
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            for (final m in kAutoSyncIntervalChoices)
              ListTile(
                title: Text(_autoSyncIntervalLabel(m)),
                trailing: m == _autoSyncIntervalMinutes
                    ? ThemeIcon('check', color: cs.primary)
                    : null,
                onTap: () => Navigator.pop(ctx, m),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await AutoSyncScheduler.writeInterval(Duration(minutes: picked));
    if (mounted) setState(() => _autoSyncIntervalMinutes = picked);
  }

  Future<void> _handleSyncNow() async {
    if (AutoSyncService().isSyncing) {
      Notify.info('Backup already running');
      return;
    }
    setState(() => _isLoading = true);
    // Pin foreground priority — a user who taps Sync Now and switches
    // apps expects the batch to finish.
    await UploadForegroundGuard().begin();
    final task = ActivityCenter().start(
        kind: ActivityKind.backup, label: 'Checking for new photos…');
    AutoSyncService().onProgress = (done, total) =>
        task.update(done, total: total, label: 'Backing up $done/$total');
    try {
      final result = await AutoSyncService().runFullSync();
      // Honest tally — a failed batch must never read as a clean one.
      final String msg;
      if (result.failed > 0) {
        final base = '${result.synced} backed up · ${result.failed} failed';
        msg = result.allFailuresOffline
            ? '$base — you appear to be offline'
            : base;
      } else if (result.synced > 0) {
        msg = '${result.synced} photo${result.synced == 1 ? '' : 's'} secured';
      } else {
        msg = 'No new photos found';
      }
      result.failed > 0 ? task.fail(msg) : task.complete(msg);
      if (mounted) _loadPreferences();
    } catch (e) {
      task.fail('Sync failed: $e');
    } finally {
      AutoSyncService().onProgress = null;
      // Balance the begin() above — without this the ref (and the
      // "Securing your file…" notification) leaked for the process
      // lifetime.
      await UploadForegroundGuard().end();
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _toggleFeatured(bool val) async {
    // Route through GalleryPrefs so the Stories tab hears about the change
    // immediately instead of catching it on the next SyncService fire.
    await GalleryPrefs().setShowFeatured(val);
    if (mounted) setState(() => _showFeatured = val);
  }

  Future<void> _toggleYearAgo(bool val) async {
    await GalleryPrefs().setShowYearAgo(val);
    if (mounted) setState(() => _showYearAgo = val);
  }

  String _providerIcon(int providerType) {
    switch (providerType) {
      case CloudAccount.providerGoogle:
        return 'googleLogo';
      case CloudAccount.providerOneDrive:
        return 'microsoftOutlookLogo';
      case CloudAccount.providerDropbox:
        return 'dropboxLogo';
      default:
        return 'cloud';
    }
  }

  /// Disconnects ONE cloud account: registry row + this provider's OAuth
  /// session. The vault (keys, DB, files) stays on the device — this is
  /// NOT sign-out-of-the-vault; that's [_forgetVaultOnDevice]. The old
  /// wording said "Sign out" while clearing only the registry row, and
  /// landed a live vault on the SIGNUP picker (MTR#1 F4).
  Future<void> _handleRemoveAccount(String accountId) async {
    final accounts = AccountRegistry().accounts;
    final account = accounts.firstWhere((a) => a.id == accountId);

    // Disconnecting the LAST account is a sign-out of the whole app: a
    // vault with no cloud is a dead end for most users, so the ruling
    // (Aug 31) is a full local reset back to onboarding. Files stay
    // encrypted in the cloud; the phrase restores them. Anything that
    // never finished uploading dies with the local index, so count it
    // and say so before asking.
    if (accounts.length == 1) {
      int pendingUploads = 0;
      try {
        pendingUploads = (await DatabaseService().getPendingUploads()).length;
      } catch (_) {}
      if (!mounted) return;
      final pendingLine = pendingUploads == 0
          ? ''
          : '\n\n$pendingUploads file${pendingUploads == 1 ? ' has' : 's have'} '
              'not finished uploading and will be lost.';
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: Text('Disconnect ${account.email}?'),
          content: Text(
            'This is your only connected account, so disconnecting it also '
            'signs you out: the vault is removed from this phone (keys, '
            'local index, cached files) and the app starts fresh.\n\n'
            'Your encrypted files stay on ${account.providerName}. Your '
            '12-word recovery phrase brings everything back, here or on '
            'any device.$pendingLine',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                'Disconnect and sign out',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              ),
            ),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
      await VaultResetService().forgetVaultOnDevice();
      if (!mounted) return;
      Navigator.pushNamedAndRemoveUntil(
          context, AppRoutes.onboarding, (r) => false);
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Disconnect ${account.email}?'),
        content: Text(
            'Files on ${account.providerName} stay there, and your vault '
            'stays on this device. You can reconnect anytime.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Disconnect',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final wasActive = AccountRegistry().activeAccount?.id == accountId;
    if (wasActive) {
      // Drop the provider's OAuth grant too — "disconnect" that leaves a
      // live token behind isn't a disconnect. Best-effort: the registry
      // removal below is the part that must not hinge on the network.
      try {
        await CloudService().signOut();
      } catch (_) {}
    }
    await AccountRegistry().removeAccount(accountId);
    CloudService().reset();

    if (wasActive) {
      final newActive = AccountRegistry().activeAccount;
      if (newActive != null) {
        DatabaseService().setCurrentAccount(newActive.id);
      } else if (mounted) {
        // Unreachable since the last-account branch above resets the app,
        // but if a race ever lands here: attach mode, never the signup
        // picker (the vault still lives on this device).
        Navigator.pushNamedAndRemoveUntil(
            context, AppRoutes.cloudSelection, (r) => false,
            arguments: CloudSelectionArgs.attach);
      }
    }
  }

  /// The true "sign out": destroys every local artifact of the vault (keys,
  /// index, caches, flags) and returns to the welcome screen. Cloud data is
  /// untouched; the recovery phrase restores access anywhere.
  Future<void> _forgetVaultOnDevice() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forget this vault on this device?'),
        content: const Text(
          'This removes the vault from this phone: keys, the local index, '
          'and all cached files.\n\nYour encrypted files stay in your '
          'cloud. To get back in, here or on any device, you need your '
          '12-word recovery phrase. If you have not written it down, stop '
          'and do that first.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Forget vault',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await VaultResetService().forgetVaultOnDevice();
    if (!mounted) return;
    Navigator.pushNamedAndRemoveUntil(
        context, AppRoutes.onboarding, (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = ThemeController().tokens;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // --- ACCOUNTS (multi-account) ---
          _SectionHeader(title: "Accounts"),
          ListenableBuilder(
            listenable: AccountRegistry(),
            builder: (context, _) {
              final accounts = AccountRegistry().accounts;
              final active = AccountRegistry().activeAccount;
              return Column(
                children: [
                  for (final a in accounts)
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: cs.primary.withAlpha(60),
                        child: ThemeIcon(_providerIcon(a.providerType), color: cs.primary, size: 20),
                      ),
                      title: Text(a.email, style: TextStyle(color: cs.onSurface)),
                      subtitle: Text(
                        active?.id == a.id ? '${a.providerName} • Active' : a.providerName,
                        style: TextStyle(color: cs.onSurface.withAlpha(140)),
                      ),
                      trailing: IconButton(
                        icon: ThemeIcon('signOut', color: cs.error),
                        onPressed: () => _handleRemoveAccount(a.id),
                      ),
                    ),
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: cs.primary.withAlpha(60),
                      child: ThemeIcon('plus', color: cs.primary, size: 20),
                    ),
                    title: Text('Add account', style: TextStyle(color: cs.primary)),
                    onTap: () => Navigator.pushNamed(context, AppRoutes.cloudSelection, arguments: true),
                  ),
                ],
              );
            },
          ),
          const Divider(),

          // --- DATA MANAGEMENT ---
          _SectionHeader(title: "Data Management"),
          
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("Max Cache Size", style: TextStyle(color: cs.onSurface)),
                    // Highlight if unsaved
                    Text(
                      "${_cacheLimitGB.toStringAsFixed(1)} GB",
                      style: TextStyle(
                        color: _hasChanges ? tokens.warning : cs.primary,
                        fontWeight: FontWeight.bold
                      )
                    ),
                  ],
                ),
                Slider(
                  value: _cacheLimitGB,
                  min: 0.1,
                  max: 2.0,
                  divisions: 19,
                  activeColor: _hasChanges ? tokens.warning : cs.primary,
                  onChanged: (val) {
                    setState(() => _cacheLimitGB = val);
                    // Note: We do NOT save here anymore. We just update UI.
                  },
                ),
                // --- SAVE BUTTON ---
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (_hasChanges)
                      Flexible(
                        child: Text("Unsaved changes",
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: tokens.warning, fontSize: 12)),
                      ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: _hasChanges ? _savePreferences : null,
                      child: const Text("Save & Apply"),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  "Older files will be removed from device when cache exceeds this limit.",
                  style: TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 11),
                ),
              ],
            ),
          ),

          ListTile(
            leading: ThemeIcon('broom', color: cs.primary),
            title: Text('Clear Local Cache', style: TextStyle(color: cs.onSurface)),
            subtitle: Text(
              _systemCacheSize == null
                  ? 'Free up $_cacheSize on device'
                  : 'CipherNest: $_cacheSize · Android system caches: '
                      '$_systemCacheSize',
              style: TextStyle(color: cs.onSurface.withAlpha(140)),
            ),
            onTap: _clearCache,
            onLongPress: _showCacheContents,
          ),
          ListTile(
            leading: ThemeIcon('ruler', color: cs.primary),
            title: Text('File size units',
                style: TextStyle(color: cs.onSurface)),
            subtitle: Text(
              ByteFormat.base == 1000
                  ? 'Match system (1,000 bytes per KB)'
                  : 'Binary (1,024 bytes per KB)',
              style: TextStyle(color: cs.onSurface.withAlpha(140)),
            ),
            onTap: _pickSizeUnits,
          ),
          ListTile(
            leading: ThemeIcon('cloudArrowUp', color: cs.primary),
            title: Text('Backup Vault Index', style: TextStyle(color: cs.onSurface)),
            subtitle: Text('Encrypt and upload your vault index to the cloud', style: TextStyle(color: cs.onSurface.withAlpha(140))),
            onTap: _handleBackup,
          ),
          ListTile(
            leading: ThemeIcon('linkSimple', color: cs.primary),
            title: Text('Active Shares', style: TextStyle(color: cs.onSurface)),
            subtitle: Text('Manage and revoke share links', style: TextStyle(color: cs.onSurface.withAlpha(140))),
            trailing: ThemeIcon('caretRight', size: 16, color: cs.onSurface.withAlpha(140)),
            onTap: () => Navigator.pushNamed(context, AppRoutes.activeShares),
          ),
          ListTile(
            leading: ThemeIcon('images', color: cs.primary),
            title: Text('Import from Gallery', style: TextStyle(color: cs.onSurface)),
            subtitle: Text('Encrypt photos already on this device', style: TextStyle(color: cs.onSurface.withAlpha(140))),
            trailing: ThemeIcon('caretRight', size: 16, color: cs.onSurface.withAlpha(140)),
            onTap: () => Navigator.pushNamed(context, AppRoutes.migration),
          ),
          ListTile(
            leading: ThemeIcon('trash', color: cs.error),
            title: Text('Recycle Bin', style: TextStyle(color: cs.onSurface)),
            subtitle: Text('Restore or permanently delete recent items', style: TextStyle(color: cs.onSurface.withAlpha(140))),
            trailing: ThemeIcon('caretRight', size: 16, color: cs.onSurface.withAlpha(140)),
            onTap: () => Navigator.pushNamed(context, AppRoutes.recycleBin),
          ),
          const Divider(),

          // --- AUTO-SYNC ---
          _SectionHeader(title: "Auto-Sync"),
          SwitchListTile(
            secondary: ThemeIcon('arrowsClockwise', color: cs.primary),
            title: Text('Auto-Sync Gallery', style: TextStyle(color: cs.onSurface)),
            subtitle: Text(
              _autoSyncEnabled ? 'Last sync: $_lastSyncDisplay' : 'Automatically encrypt new photos',
              style: TextStyle(color: cs.onSurface.withAlpha(140)),
            ),
            value: _autoSyncEnabled,
            onChanged: _toggleAutoSync,
          ),
          if (_autoSyncEnabled) ...[
            ListTile(
              leading: const SizedBox(width: 24),
              title: Text('Backed-up albums',
                  style: TextStyle(color: cs.onSurface)),
              subtitle: Text(
                'Choose which device albums are protected',
                style:
                    TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 12),
              ),
              trailing:
                  ThemeIcon('caretRight', size: 16, color: cs.onSurface),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const BackupAlbumsScreen()),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'When to sync',
                    style: TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  _AutoSyncModePicker(
                    mode: _autoSyncMode,
                    onChanged: _setAutoSyncMode,
                  ),
                ],
              ),
            ),
            if (_autoSyncMode == AutoSyncMode.background) ...[
              ListTile(
                leading: const SizedBox(width: 24),
                title: Text('How often',
                    style: TextStyle(color: cs.onSurface)),
                subtitle: Text(
                  _autoSyncIntervalLabel(_autoSyncIntervalMinutes),
                  style: TextStyle(
                      color: cs.onSurface.withAlpha(140), fontSize: 12),
                ),
                trailing:
                    ThemeIcon('caretRight', size: 16, color: cs.onSurface),
                onTap: _pickAutoSyncInterval,
              ),
              ListTile(
                leading: const SizedBox(width: 24),
                title: Text('Last background sync',
                    style: TextStyle(color: cs.onSurface)),
                subtitle: Text(
                  _lastBgSyncDisplay,
                  style: TextStyle(
                      color: cs.onSurface.withAlpha(140), fontSize: 12),
                ),
              ),
              if (_batteryExempt == false)
                ListTile(
                  leading: const SizedBox(width: 24),
                  title: Text('Background sync being killed?',
                      style: TextStyle(color: ThemeController().tokens.warning)),
                  subtitle: Text(
                    'Battery optimization can stop scheduled syncs. Tap to '
                    'exempt CipherNest.',
                    style: TextStyle(
                        color: cs.onSurface.withAlpha(140), fontSize: 12),
                  ),
                  trailing:
                      ThemeIcon('caretRight', size: 16, color: cs.onSurface),
                  onTap: () async {
                    await BatteryOptimization.openSettings();
                    // Re-check when the user comes back to this screen.
                    _loadPreferences();
                  },
                ),
            ],
            ListTile(
              leading: const SizedBox(width: 24),
              title: Text('Sync Now', style: TextStyle(color: cs.primary)),
              subtitle: Text('Manually check for new photos right now', style: TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 12)),
              trailing: ThemeIcon('play', selected: true, color: cs.primary),
              onTap: _handleSyncNow,
            ),
          ],

          const Divider(),

          // --- GALLERY ---
          _SectionHeader(title: "Gallery"),
          SwitchListTile(
            secondary: ThemeIcon('sparkle', color: cs.primary),
            title: Text('Show Featured Content', style: TextStyle(color: cs.onSurface)),
            subtitle: Text('Display stories and highlights', style: TextStyle(color: cs.onSurface.withAlpha(140))),
            value: _showFeatured,
            onChanged: _toggleFeatured,
          ),
          SwitchListTile(
            secondary: ThemeIcon('clockCounterClockwise', color: cs.primary),
            title: Text('A Year Ago Memories', style: TextStyle(color: cs.onSurface)),
            subtitle: Text('Show photos from this day last year', style: TextStyle(color: cs.onSurface.withAlpha(140))),
            value: _showYearAgo,
            onChanged: _toggleYearAgo,
          ),

          const Divider(),

          // --- APPEARANCE ---
          _SectionHeader(title: "Appearance"),
          ListenableBuilder(
            listenable: ThemeController(),
            builder: (context, _) {
              final tc = ThemeController();
              return Column(
                children: [
                  ListTile(
                    leading: ThemeIcon(
                      tc.brightness == Brightness.dark ? 'moon' : 'sun',
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    title: Text('Appearance mode',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface)),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      // scaleDown is a no-op until the three segments outgrow
                      // the tile (narrow phones at large font scale).
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: SegmentedButton<AppThemeMode>(
                          segments: const [
                            ButtonSegment(
                                value: AppThemeMode.system,
                                label: Text('System')),
                            ButtonSegment(
                                value: AppThemeMode.light, label: Text('Light')),
                            ButtonSegment(
                                value: AppThemeMode.dark, label: Text('Dark')),
                          ],
                          selected: {tc.mode},
                          onSelectionChanged: (s) => tc.setMode(s.first),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(
                      'Theme',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Column(
                      children: [
                        for (final pack in ThemePack.values)
                          _ThemePackTile(
                            pack: pack,
                            selected: tc.pack == pack,
                            onTap: () => tc.setPack(pack),
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),

          const Divider(),
          // ... Security Section ...
          _SectionHeader(title: "Security"),
          ListTile(
            leading: ThemeIcon('lock', color: cs.primary),
            title: Text('Auto-lock', style: TextStyle(color: cs.onSurface)),
            subtitle: Text(
              _autoLockLabel(_autoLockMinutes),
              style: TextStyle(color: cs.onSurface.withAlpha(140)),
            ),
            trailing: ThemeIcon('caretRight', size: 16, color: cs.onSurface.withAlpha(140)),
            onTap: _pickAutoLock,
          ),
          // Hidden outright when the device can never support it (no sensor /
          // no lock screen) — an impossible toggle is worse than none.
          if (_bioCapability != BiometricCapability.noHardware &&
              _bioCapability != BiometricCapability.noLockScreen)
            SwitchListTile(
              secondary: ThemeIcon('fingerprint', color: cs.primary),
              title: Text('Unlock with fingerprint',
                  style: TextStyle(color: cs.onSurface)),
              subtitle: Text(
                _bioSubtitleOverride ??
                    (_bioCapability == BiometricCapability.noneEnrolled
                        ? 'No fingerprints enrolled — add one in Android Settings'
                        : 'Hardware-backed. Your master password always works.'),
                style: TextStyle(color: cs.onSurface.withAlpha(140)),
              ),
              value: _bioEnabled,
              onChanged: _bioCapability == BiometricCapability.available
                  ? _toggleBiometric
                  : null,
            ),
          ListTile(
            leading: ThemeIcon('key', color: cs.primary),
            title: Text('Key Management', style: TextStyle(color: cs.onSurface)),
            subtitle: Text('Check encryption integrity', style: TextStyle(color: cs.onSurface.withAlpha(140))),
            trailing: ThemeIcon('caretRight', size: 16, color: cs.onSurface.withAlpha(140)),
            onTap: () => Navigator.pushNamed(context, AppRoutes.keyManagement),
          ),
          ListTile(
            leading: ThemeIcon('heart', color: cs.primary),
            title: Text('Vault Health', style: TextStyle(color: cs.onSurface)),
            subtitle: Text(_vaultHealthSubtitle(cs),
                style: TextStyle(color: cs.onSurface.withAlpha(140))),
            trailing: _vaultHealthScanning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : ThemeIcon('caretRight',
                    size: 16, color: cs.onSurface.withAlpha(140)),
            onTap: _vaultHealthScanning ? null : _runVaultHealthScan,
          ),
          ListTile(
            leading: ThemeIcon('smartphone', color: cs.primary),
            title: Text('Devices', style: TextStyle(color: cs.onSurface)),
            subtitle: Text('Name this device, see others on your vault',
                style: TextStyle(color: cs.onSurface.withAlpha(140))),
            trailing: ThemeIcon('caretRight',
                size: 16, color: cs.onSurface.withAlpha(140)),
            onTap: _openDevices,
          ),
          // Storage cleanup for blobs sealed under a PREVIOUS vault key
          // (kept during a "start over"). Hidden while there are none.
          FutureBuilder<List<CnestFile>>(
            key: ValueKey('prior_key_$_priorKeyRefresh'),
            future: DatabaseService().getPriorKeyFiles(),
            builder: (context, snap) {
              final rows = snap.data ?? const <CnestFile>[];
              if (rows.isEmpty) return const SizedBox.shrink();
              final total = rows.fold<int>(0, (s, f) => s + f.sizeBytes);
              return ListTile(
                leading: ThemeIcon('lockKey', color: cs.primary),
                title: Text('Files from a previous phrase',
                    style: TextStyle(color: cs.onSurface)),
                subtitle: Text(
                    '${rows.length} locked file${rows.length == 1 ? '' : 's'}'
                    ' · ${formatBytes(total)} · tap to remove',
                    style: TextStyle(color: cs.onSurface.withAlpha(140))),
                trailing: ThemeIcon('caretRight',
                    size: 16, color: cs.onSurface.withAlpha(140)),
                onTap: () => _cleanupPriorKeyFiles(rows),
              );
            },
          ),
          ListTile(
            leading: ThemeIcon('signOut', color: cs.error),
            title: Text('Forget this vault on this device',
                style: TextStyle(color: cs.error)),
            subtitle: Text(
                'Remove keys, index, and caches here. Cloud files stay; '
                'your recovery phrase gets you back in.',
                style: TextStyle(color: cs.onSurface.withAlpha(140))),
            onTap: _forgetVaultOnDevice,
          ),
          ValueListenableBuilder<MetadataMigrationState>(
            valueListenable: MetadataMigrationService().state,
            builder: (context, mig, _) {
              final subtitle = switch (mig.phase) {
                MetadataMigrationPhase.running =>
                  'Encrypting ${mig.done}/${mig.total}…',
                MetadataMigrationPhase.done => mig.failed == 0
                    ? 'All cloud metadata is encrypted'
                    : '${mig.failed} of ${mig.total} failed — tap to retry',
                MetadataMigrationPhase.error =>
                  'Failed — tap to retry',
                MetadataMigrationPhase.idle =>
                  'Seal filenames in cloud metadata',
              };
              return ListTile(
                leading: ThemeIcon('shieldCheck', color: cs.primary),
                title: Text('Encrypt cloud metadata',
                    style: TextStyle(color: cs.onSurface)),
                subtitle: Text(subtitle,
                    style: TextStyle(color: cs.onSurface.withAlpha(140))),
                trailing: mig.phase == MetadataMigrationPhase.running
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : ThemeIcon('caretRight',
                        size: 16, color: cs.onSurface.withAlpha(140)),
                onTap: MetadataMigrationService().isRunning
                    ? null
                    : _runMetadataMigration,
              );
            },
          ),
          AnimatedBuilder(
            animation: AudioPlayerService(),
            builder: (context, _) => SwitchListTile(
              secondary: ThemeIcon('musicNote', color: cs.primary),
              title: Text('Track titles on lock screen',
                  style: TextStyle(color: cs.onSurface)),
              subtitle: Text(
                AudioPlayerService().showTitlesOnLockScreen
                    ? 'Media notification shows what\'s playing'
                    : 'Media notification shows "CipherNest Audio"',
                style: TextStyle(color: cs.onSurface.withAlpha(140)),
              ),
              value: AudioPlayerService().showTitlesOnLockScreen,
              onChanged: (v) =>
                  AudioPlayerService().setShowTitlesOnLockScreen(v),
            ),
          ),

          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Your encrypted vault lives in your cloud under a folder named '
              '"CipherNest". The files there are unreadable by design — don\'t '
              'delete or move them from your cloud\'s website; use the Recycle '
              'Bin in this app instead.',
              style: TextStyle(color: cs.onSurface.withAlpha(110), fontSize: 12),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              'CipherNest v1.0.0 Beta',
              style: TextStyle(color: cs.onSurface.withAlpha(60)),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

/// Segmented picker for the auto-sync cadence. Two pills:
///   Background   — periodic Workmanager task every ~6h, plus foreground.
///   When I open  — foreground trigger only (SyncService.syncNow / pull).
/// Off is handled by the top-level SwitchListTile, so this widget only
/// renders when auto-sync is already enabled.
class _AutoSyncModePicker extends StatelessWidget {
  const _AutoSyncModePicker({
    required this.mode,
    required this.onChanged,
  });

  final AutoSyncMode mode;
  final ValueChanged<AutoSyncMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _ModePill(
            label: 'Background',
            sub: 'Every few hours',
            selected: mode == AutoSyncMode.background,
            onTap: () => onChanged(AutoSyncMode.background),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ModePill(
            label: 'When I open',
            sub: 'App-open only',
            selected: mode == AutoSyncMode.foregroundOnly,
            onTap: () => onChanged(AutoSyncMode.foregroundOnly),
          ),
        ),
      ],
    );
  }
}

class _ModePill extends StatelessWidget {
  const _ModePill({
    required this.label,
    required this.sub,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String sub;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return Material(
      color: selected
          ? cs.primary.withValues(alpha: 0.14)
          : cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(t.rInput),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(t.rInput),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected
                  ? cs.primary
                  : cs.outline.withValues(alpha: 0.3),
              width: selected ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(t.rInput),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: selected ? cs.primary : cs.onSurface,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                sub,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.6),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One tile in the theme-pack picker. Renders in the pack's OWN tokens —
/// its own surface colour, corner radius, font, and card-art image — so the
/// tile itself becomes the preview, independent of the currently-applied
/// theme. Mode (dark/light) follows the ThemeController so toggling
/// brightness updates every tile in place.
class _ThemePackTile extends StatelessWidget {
  final ThemePack pack;
  final bool selected;
  final VoidCallback onTap;
  const _ThemePackTile({
    required this.pack,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final mode = ThemeController().brightness;
    final t = ThemePackTokens.forPackMode(pack, mode);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(t.rCard),
          child: Container(
            padding: EdgeInsets.all(t.pad * 0.6),
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(t.rCard),
              border: Border.all(
                color: selected ? t.accent : t.hairline,
                width: selected ? 2 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              pack.label,
                              style: TextStyle(
                                fontFamily: t.titleFontFamily,
                                color: t.fg,
                                fontWeight: FontWeight.w600,
                                fontSize: 17,
                                letterSpacing: t.titleLetterSpacing,
                              ),
                            ),
                          ),
                          if (selected)
                            ThemeIcon('checkCircle',
                                selected: true, color: t.accent, size: 20),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        pack.tagline,
                        style: TextStyle(
                          fontFamily: t.fontFamily,
                          color: t.fg2,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Aa Bb Cc  0123',
                        style: TextStyle(
                          fontFamily: t.titleFontFamily,
                          color: t.accent,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: t.titleLetterSpacing,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(t.rIc),
                  child: Image.asset(
                    t.cardArtAsset,
                    width: 76,
                    height: 76,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 76,
                      height: 76,
                      color: t.surface2,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
/// Bottom sheet detailing a Vault Health scan. Orphans and missing files are
/// SURFACED, never auto-deleted — the user decides. (Recover/forget actions
/// are wired in a follow-up; this ships the honest report first.)
class _VaultHealthSheet extends StatelessWidget {
  final VaultHealthReport report;
  const _VaultHealthSheet({required this.report});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        // No-op while the report fits; a multi-finding report scrolls on
        // short viewports instead of overflowing the sheet.
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ThemeIcon(report.isHealthy ? 'shieldCheck' : 'warning',
                    color: report.isHealthy ? cs.primary : cs.error, size: 22),
                const SizedBox(width: 10),
                Text('Vault Health',
                    style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 16),
            if (report.isHealthy)
              Text('Every file in your cloud is accounted for, and every '
                  'file the app knows about has its data. Nothing to do.',
                  style: TextStyle(color: cs.onSurface.withAlpha(180))),
            if (report.orphanBlobIds.isNotEmpty) ...[
              _row(cs, 'file', '${report.orphanBlobIds.length} orphaned file'
                  '${report.orphanBlobIds.length == 1 ? '' : 's'}',
                  'Encrypted data in your cloud that the app no longer '
                  'references. Nothing is deleted automatically — a future '
                  'update will let you recover or remove these.'),
            ],
            if (report.missingBlobFileIds.isNotEmpty) ...[
              _row(cs, 'warningCircle',
                  '${report.missingBlobFileIds.length} missing file'
                  '${report.missingBlobFileIds.length == 1 ? '' : 's'}',
                  'Files the app expects but whose encrypted data is gone '
                  'from your cloud — likely deleted in the cloud\'s own web '
                  'interface. Their entries remain so you know what was lost.'),
            ],
            if (report.unreadableSegments > 0) ...[
              _row(cs, 'lockKey', '${report.unreadableSegments} unreadable '
                  'sync record${report.unreadableSegments == 1 ? '' : 's'}',
                  'Multi-device sync data that could not be decrypted. These '
                  'are retried on every sync and never discarded.'),
            ],
            if (report.clockSkewDetected) ...[
              _row(cs, 'clockCountdown', 'Check a device\'s clock',
                  'One of your devices has a clock set far from the correct '
                  'time. Your files are safe, but until it is corrected that '
                  'device may win when the same file is edited on two devices '
                  'at once. Set its date & time to automatic.'),
            ],
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ),
          ],
          ),
        ),
      ),
    );
  }

  Widget _row(ColorScheme cs, String icon, String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ThemeIcon(icon, color: cs.error, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: cs.onSurface, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(body,
                      style: TextStyle(
                          color: cs.onSurface.withAlpha(160),
                          fontSize: 12,
                          height: 1.35)),
                ],
              ),
            ),
          ],
        ),
      );
}

/// Bottom sheet: rename this device and list every device on the vault.
class _DevicesSheet extends StatefulWidget {
  final List<KnownDevice> devices;
  final String currentName;
  final Future<void> Function(String) onRename;
  const _DevicesSheet({
    required this.devices,
    required this.currentName,
    required this.onRename,
  });

  @override
  State<_DevicesSheet> createState() => _DevicesSheetState();
}

class _DevicesSheetState extends State<_DevicesSheet> {
  late final TextEditingController _name =
      TextEditingController(text: widget.currentName);
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        // Sheet is scroll-controlled (see _openDevices): the keyboard inset
        // above shrinks the area, and this lets the list scroll inside it.
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ThemeIcon('smartphone', color: cs.primary, size: 22),
                const SizedBox(width: 10),
                Text('Devices', style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 16),
            Text('This device\'s name',
                style: TextStyle(
                    color: cs.onSurface.withAlpha(180), fontSize: 13)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _name,
                    decoration: const InputDecoration(isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving
                      ? null
                      : () async {
                          setState(() => _saving = true);
                          await widget.onRename(_name.text);
                          if (context.mounted) Navigator.pop(context);
                        },
                  child: const Text('Save'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text('On this vault',
                style: TextStyle(
                    color: cs.onSurface.withAlpha(180), fontSize: 13)),
            const SizedBox(height: 6),
            if (widget.devices.isEmpty)
              Text('Only this device so far.',
                  style: TextStyle(color: cs.onSurface.withAlpha(140))),
            for (final d in widget.devices)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: ThemeIcon(d.isThisDevice ? 'smartphone' : 'cloudArrowDown',
                    color: cs.primary),
                title: Text(d.name, style: TextStyle(color: cs.onSurface)),
                subtitle: d.isThisDevice
                    ? Text('This device',
                        style: TextStyle(color: cs.onSurface.withAlpha(140)))
                    : null,
              ),
          ],
          ),
        ),
      ),
    );
  }
}
