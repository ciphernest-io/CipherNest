import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../widgets/ciphernest_logo.dart';
import '../../config/app_info.dart';
import '../../utils/byte_format.dart';
import '../../widgets/activity_sheet.dart';
import '../../widgets/theme_icon.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart'; // ENABLED
import '../../../services/subscription_service.dart';
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
import '../../../services/backup_selection_service.dart';
import 'cache_usage_card.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../config/theme_packs.dart';
import '../../config/theme_controller.dart';
import '../../config/theme_reveal.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.initialSection});

  /// One of the kSettings*Section keys to deep-link straight into a category
  /// page (from the gallery Menu). Null opens the hub. Passed via the
  /// constructor rather than route arguments because the '/settings' route
  /// does not forward RouteSettings.
  final String? initialSection;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _cacheSize = "Calculating...";

  /// Bytes in the temp dir that CipherNest did NOT write (OS thumbnail /
  /// engine caches). Null when zero — the subtitle stays clean.
  String? _systemCacheSize;
  double _cacheLimitGB = 0.5; // Persisted on release; no Save button.

  bool _isLoading = true;

  // Auto-Sync — persisted mode. The SwitchListTile at the top toggles the
  // whole feature on/off; the segmented picker below chooses between
  // background and foreground-only modes.
  AutoSyncMode _autoSyncMode = AutoSyncMode.off;
  bool get _autoSyncEnabled => _autoSyncMode != AutoSyncMode.off;
  // Which albums are enrolled: "All albums" or "Selected albums".
  String _backupScope = 'All albums';
  String _lastSyncDisplay = 'Never';
  int _autoSyncIntervalMinutes = kAutoSyncIntervalDefaultMinutes;
  String _lastBgSyncDisplay = "hasn't run yet";
  // Null = unknown / not Android.
  bool? _batteryExempt;

  // Gallery
  bool _showFeatured = true;
  /// Per-kind story toggles under the Featured master switch.
  final Map<String, bool> _storyFlags = {};

  // Security
  int _autoLockMinutes = AppLockService.defaultMinutes;
  bool _keepPlayingOnClose = false;
  BiometricCapability _bioCapability = BiometricCapability.unavailable;
  // True for vaults created with "Continue without password". There is no
  // password to fall back on, so fingerprint unlock is never offered.
  bool _passwordlessVault = false;
  bool _bioEnabled = false;
  String? _bioSubtitleOverride; // invalidation notice, shown once detected

  // Deep-link: the gallery Menu's "Settings" tile passes kSettingsGallerySection
  // so we open the Gallery category page straight away.
  final ScrollController _scrollCtrl = ScrollController();
  bool _anchorHandled = false;
  // Ticked by [_setState]; open category detail pages listen to it so state
  // that lives on this State object stays live inside the pushed route.
  final ValueNotifier<int> _rev = ValueNotifier<int>(0);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_anchorHandled) return;
    _anchorHandled = true;
    final arg = widget.initialSection;
    // Deep-link straight into a category page from the gallery Menu.
    String? title;
    List<Widget> Function(ColorScheme)? builder;
    if (arg == kSettingsGallerySection) {
      title = 'Gallery';
      builder = _galleryChildren;
    } else if (arg == kSettingsBackupSection) {
      title = 'Backup & sync';
      builder = _backupChildren;
    } else if (arg == kSettingsMusicSection) {
      title = 'Music';
      builder = _musicChildren;
    }
    if (title == null || builder == null) return;
    // Render the category AS this screen instead of pushing it on top of
    // the Settings root: back from the gallery Menu's "Settings" tile then
    // returns to the Menu, not to a Settings page the user never opened.
    _inlineTitle = title;
    _inlineChildren = builder;
  }

  /// Set when this screen was opened straight into one category (see
  /// [didChangeDependencies]); the root list is not shown at all.
  String? _inlineTitle;
  List<Widget> Function(ColorScheme)? _inlineChildren;

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
    _scrollCtrl.dispose();
    _rev.dispose();
    super.dispose();
  }

  /// setState that also ticks [_rev], so any category detail page currently
  /// open reflects the change immediately.
  void _setState(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
    _rev.value++;
  }

  // --- NEW: PERSISTENCE LOGIC ---
  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = await AutoSyncScheduler.readMode();
    final interval = await AutoSyncScheduler.readInterval();
    final batteryExempt = await BatteryOptimization.isExempt();
    final backupSel = await BackupSelectionService().load();
    if (mounted) {
      final lastRunMs = prefs.getInt('auto_sync_last_run') ?? 0;
      final lastBgMs = prefs.getInt('auto_sync_last_bg_run') ?? 0;
      _setState(() {
        _cacheLimitGB = prefs.getDouble('cache_limit') ?? 0.5;
        _autoSyncMode = mode;
        _backupScope = backupSel.mode == BackupMode.all
            ? 'All albums'
            : 'Selected albums';
        _autoSyncIntervalMinutes = interval.inMinutes;
        _showFeatured = prefs.getBool('gallery_show_featured') ?? true;
        for (final k in GalleryPrefs.subKinds) {
          _storyFlags[k.$1] = prefs.getBool(k.$1) ?? true;
        }
        _autoLockMinutes = prefs.getInt(AppLockService.prefsKeyMinutes) ??
            AppLockService.defaultMinutes;
        _keepPlayingOnClose =
            prefs.getBool(AppLockService.prefsKeyKeepPlaying) ?? false;
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
        notice = 'Device security settings changed. Re-enable to continue '
            'using fingerprint unlock.';
      }
    }
    final passwordless = await KeyManagerService().isPasswordless();
    if (!mounted) return;
    _setState(() {
      _bioCapability = capability;
      _passwordlessVault = passwordless;
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
    final devices = ValueNotifier<List<KnownDevice>>(
        await DeviceRegistryService().listDevices(accountId: account.id));
    final currentName = await DeviceRegistryService().deviceName();
    if (!mounted) return;
    var open = true;
    Future<void> refresh() async {
      final latest =
          await DeviceRegistryService().listDevices(accountId: account.id);
      if (open) devices.value = latest;
    }

    // The list is replayed from the LOCAL log, so another device's rename
    // only appears after a pull. Pull while the sheet is up rather than
    // leaving the user to find the gallery's pull-to-refresh.
    unawaited(SyncCoordinator().sync().then((_) => refresh()));
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
          await refresh();
        },
      ),
    );
    open = false;
    devices.dispose();
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
    _setState(() => _vaultHealthScanning = true);
    VaultHealthReport? report;
    try {
      report = await VaultHealthService().scan(accountId: account.id);
    } catch (e) {
      Notify.error('Vault Health scan failed: $e');
    }
    if (!mounted) return;
    _setState(() {
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
    if (mounted) _setState(() => _priorKeyRefresh++);
  }

  Future<void> _toggleBiometric(bool v) async {
    if (!v) {
      await KeyManagerService().disableBiometric();
      if (mounted) {
        _setState(() {
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
      _setState(() {
        _bioEnabled = true;
        _bioSubtitleOverride = null;
      });
    } on BiometricUnlockException catch (e) {
      if (e.code == BiometricUnlockError.userCanceled) return;
      Notify.error('Could not enable fingerprint unlock (${e.code.name})');
    }
  }

  /// Persist the cache limit and apply it right away. Called when the slider
  /// is released — there is no Save button, the choice just sticks.
  Future<void> _persistCacheLimit() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('cache_limit', _cacheLimitGB);
    await CacheManagerService().enforceCacheLimit();
    if (mounted) _loadStats();
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
      _setState(() {
        _cacheSize = _formatBytes(appBytes);
        _systemCacheSize = systemBytes > 0 ? _formatBytes(systemBytes) : null;
        _isLoading = false;
      });
    }
  }

  static String _autoLockLabel(int minutes) {
    if (minutes <= 0) return 'Never (vault stays unlocked)';
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
    if (mounted) _setState(() => _autoLockMinutes = picked);
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
              (1000, 'Match system (1,000 bytes per KB)'),
              (1024, 'Binary (1,024 bytes per KB)'),
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
    _setState(() {});
    // Reformat the cached size string with the new base.
    _loadStats();
  }

  Future<void> _clearCache() async {
    final tempDir = await getTemporaryDirectory();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
      await tempDir.create();
    }
    // Bump the service so the CacheUsageCard (which recomputes only on this
    // notifier) re-scans too — clearing bypasses the service's own delete
    // paths, so without this the card kept showing the pre-clear breakdown.
    CacheManagerService().notifyCacheChanged();
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
    _setState(() => _isLoading = true);
    try {
      // backupDatabase never throws — it returns whether the snapshot
      // landed. Failure toasts itself via the quiet task; a manual tap
      // still deserves a positive receipt on success.
      final ok = await DatabaseBackupService().backupDatabase();
      if (ok) Notify.info('Vault index backed up');
    } finally {
      if (mounted) _setState(() => _isLoading = false);
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
    if (mounted) _setState(() => _autoSyncMode = mode);
    // Which albums? All vs a checklist, plus the include-existing shortcut.
    if (enabled && mounted) await showBackupAlbumChoiceSheet(context);
  }

  /// Switches between [AutoSyncMode.background] and [AutoSyncMode.foregroundOnly]
  /// without changing whether auto-sync is enabled overall. Called from the
  /// segmented picker that appears under the top-level toggle.
  Future<void> _setAutoSyncMode(AutoSyncMode mode) async {
    if (mode == _autoSyncMode || mode == AutoSyncMode.off) return;
    await AutoSyncScheduler.writeMode(mode);
    if (mounted) _setState(() => _autoSyncMode = mode);
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
    if (mounted) _setState(() => _autoSyncIntervalMinutes = picked);
  }

  Future<void> _handleSyncNow() async {
    if (AutoSyncService().isSyncing) {
      Notify.info('Backup already running');
      return;
    }
    _setState(() => _isLoading = true);
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
            ? '$base, you appear to be offline'
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
      if (mounted) _setState(() => _isLoading = false);
    }
  }

  Future<void> _toggleFeatured(bool val) async {
    // Route through GalleryPrefs so the Stories tab hears about the change
    // immediately instead of catching it on the next SyncService fire.
    await GalleryPrefs().setShowFeatured(val);
    if (mounted) _setState(() => _showFeatured = val);
  }

  Future<void> _setStoryFlag(String key, bool val) async {
    await GalleryPrefs().set(key, val);
    if (mounted) _setState(() => _storyFlags[key] = val);
  }

  /// The real provider brand mark, rendered on a white chip. Falls back to a
  /// generic cloud glyph for an unknown provider.
  Widget _providerLogo(int providerType, {double size = 22}) {
    final asset = switch (providerType) {
      CloudAccount.providerGoogle => 'assets/images/brands/google_drive.png',
      CloudAccount.providerOneDrive => 'assets/images/brands/onedrive.svg',
      CloudAccount.providerDropbox => 'assets/images/brands/dropbox.png',
      _ => null,
    };
    if (asset == null) {
      return ThemeIcon('cloud', size: size, color: Colors.blueGrey);
    }
    if (asset.endsWith('.svg')) {
      return SvgPicture.asset(asset, width: size, height: size);
    }
    return Image.asset(asset, width: size, height: size, fit: BoxFit.contain);
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
    // The account's metadata and any decrypted large files go with it
    // (MASVS F-20). Thumbnails are device-wide cache and are left to the
    // cache manager's own limit.
    await DatabaseService().deleteAccountData(accountId);
    await CacheManagerService().purgeAllLargePlaintext();

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

  /// Route name of every category page pushed by [_openSection].
  static const _kSectionRoute = '/settings/section';

  static bool _isSettingsRoute(Route<dynamic> r) =>
      r.settings.name == AppRoutes.settings ||
      r.settings.name == _kSectionRoute;

  /// Two ways out of a category page, two destinations. The system back
  /// (gesture or button) leaves Settings altogether, back to the gallery or
  /// Music or wherever Settings was opened from. The arrow in the bar goes
  /// up one level to the Settings list. The arrow calls `pop` directly, which
  /// does not consult PopScope; only the system back is intercepted.
  Widget _sectionScaffold(
      String title, List<Widget> Function(ColorScheme) children) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        Navigator.of(context).popUntil((r) => !_isSettingsRoute(r));
      },
      child: Builder(
        builder: (ctx) => Scaffold(
          appBar: AppBar(
            leading: BackButton(onPressed: () => Navigator.of(ctx).pop()),
            title: Text(title),
          ),
          body: ValueListenableBuilder<int>(
            valueListenable: _rev,
            builder: (ctx, _, _) => ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 32),
              children: children(Theme.of(ctx).colorScheme),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final inline = _inlineChildren;
    if (inline != null) {
      // One route deep: both exits lead to the opener, so no PopScope.
      return Scaffold(
        appBar: AppBar(title: Text(_inlineTitle ?? 'Settings')),
        body: ValueListenableBuilder<int>(
          valueListenable: _rev,
          builder: (ctx, _, _) => ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 32),
            children: inline(Theme.of(ctx).colorScheme),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        controller: _scrollCtrl,
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _CategoryTile(
            icon: 'googleLogo',
            title: 'Account',
            subtitle: 'Connected clouds, Plus, activity log',
            onTap: () => _openSection('Account', _accountChildren),
          ),
          _CategoryTile(
            icon: 'database',
            title: 'Storage & cache',
            subtitle: 'Cache usage, size limit, units, recycle bin',
            onTap: () => _openSection('Storage & cache', _storageChildren),
          ),
          _CategoryTile(
            icon: 'cloudArrowUp',
            title: 'Backup & sync',
            subtitle: 'Auto-sync, import, vault index backup',
            onTap: () => _openSection('Backup & sync', _backupChildren),
          ),
          _CategoryTile(
            icon: 'images',
            title: 'Gallery',
            subtitle: 'Stories and memories',
            onTap: () => _openSection('Gallery', _galleryChildren),
          ),
          _CategoryTile(
            icon: 'musicNotes',
            title: 'Music',
            subtitle: 'Playback and the media notification',
            onTap: () => _openSection('Music', _musicChildren),
          ),
          _CategoryTile(
            icon: cs.brightness == Brightness.dark ? 'moon' : 'sun',
            title: 'Appearance',
            subtitle: 'Theme mode and color packs',
            onTap: () => _openSection('Appearance', _appearanceChildren),
          ),
          _CategoryTile(
            icon: 'shieldCheck',
            title: 'Security',
            subtitle: 'Password, phrase, lock, keys, devices',
            onTap: () => _openSection('Security', _securityChildren),
          ),
          _CategoryTile(
            icon: 'info',
            title: 'About',
            subtitle: kAppVersionLabel,
            onTap: () => _openSection('About', _aboutChildren),
          ),
        ],
      ),
    );
  }

  /// Push a category detail page. Its body rebuilds whenever [_rev] ticks (via
  /// [_setState]) so toggles, the cache slider and pickers reflect state that
  /// lives on this State object even though they render inside the pushed route.
  void _openSection(
      String title, List<Widget> Function(ColorScheme) children) {
    Navigator.of(context).push(MaterialPageRoute(
      settings: const RouteSettings(name: _kSectionRoute),
      builder: (_) => _sectionScaffold(title, children),
    ));
  }

  List<Widget> _accountChildren(ColorScheme cs) {
    return <Widget>[
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
                        backgroundColor: Colors.white,
                        child: Padding(
                          padding: const EdgeInsets.all(7),
                          child: _providerLogo(a.providerType),
                        ),
                      ),
                      title: Text(a.email, style: TextStyle(color: cs.onSurface)),
                      subtitle: Text(
                        active?.id == a.id ? '${a.providerName} • Active' : a.providerName,
                        style: TextStyle(color: cs.onSurface.withAlpha(140)),
                      ),
                      trailing: IconButton(
                        icon: ThemeIcon('signOut',
                            color: cs.onSurface.withAlpha(160)),
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
      const Divider(height: 24),
      // The ONLY purchase and restore entry point for a user who has
      // finished onboarding. Before this, the paywall was reachable from the
      // three setup screens and nowhere else, so an existing subscriber who
      // reinstalled had no way to reach Restore purchases at all.
      ListenableBuilder(
        listenable: SubscriptionService(),
        builder: (context, _) => ListTile(
            leading: ThemeIcon('workspace_premium', color: cs.primary),
            title: Text(
                SubscriptionService().isPlus
                    ? 'CipherNest Plus'
                    : 'Upgrade to Plus',
                style: TextStyle(color: cs.onSurface)),
            subtitle: Text(
                switch (SubscriptionService().plan) {
                  PlusPlan.monthly =>
                    'Monthly plan. Tap to switch to Yearly or Lifetime.',
                  PlusPlan.yearly => 'Yearly plan. Tap to switch to Lifetime.',
                  PlusPlan.lifetime => 'Lifetime. Unlimited uploads.',
                  PlusPlan.unknown => 'Active. Unlimited uploads.',
                  PlusPlan.none =>
                    'Free stores 1,000 files. Plus removes the limit.',
                },
                style: TextStyle(color: cs.onSurface.withAlpha(140))),
            trailing: ThemeIcon('caretRight',
                size: 16, color: cs.onSurface.withAlpha(140)),
            onTap: () async {
              await Navigator.pushNamed(context, AppRoutes.subscription);
              // Entitlement may have changed while the paywall was open.
              if (mounted) _setState(() {});
            },
          ),
      ),
      ListTile(
        leading: ThemeIcon('browseActivity', color: cs.primary),
        title: Text('Activity log', style: TextStyle(color: cs.onSurface)),
        subtitle: Text('Running tasks and recent results',
            style: TextStyle(color: cs.onSurface.withAlpha(140))),
        trailing: ThemeIcon('caretRight',
            size: 16, color: cs.onSurface.withAlpha(140)),
        onTap: () => showActivitySheet(context),
      ),
    ];
  }

  List<Widget> _storageChildren(ColorScheme cs) {
    final tokens = ThemeController().tokens;
    return <Widget>[
      CacheUsageCard(
        onClear: _clearCache,
        onShowContents: _showCacheContents,
        clearSubtitle: _systemCacheSize == null
            ? 'Free up $_cacheSize on this device'
            : 'CipherNest: $_cacheSize · Android system caches: '
                '$_systemCacheSize',
      ),
      Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        padding: EdgeInsets.all(tokens.pad),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(tokens.rCard),
          border: Border.all(color: cs.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ThemeIcon('hardDrive', color: cs.primary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Max cache size',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600, fontSize: 15)),
                ),
                Text(
                  '${_cacheLimitGB.toStringAsFixed(1)} GB',
                  style: TextStyle(
                      color: cs.primary,
                      fontWeight: FontWeight.bold,
                      fontSize: 15),
                ),
              ],
            ),
            Slider(
              value: _cacheLimitGB,
              min: 0.1,
              max: 2.0,
              divisions: 19,
              activeColor: cs.primary,
              // Live label while dragging; persist + evict on release.
              onChanged: (val) => _setState(() => _cacheLimitGB = val),
              onChangeEnd: (_) => _persistCacheLimit(),
            ),
            Text(
              'Older files are removed from this device when the cache passes '
              'this limit.',
              style: TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 11),
            ),
          ],
        ),
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
            leading: ThemeIcon('trash', color: cs.primary),
            title: Text('Recycle Bin', style: TextStyle(color: cs.onSurface)),
            subtitle: Text('Restore or permanently delete recent items', style: TextStyle(color: cs.onSurface.withAlpha(140))),
            trailing: ThemeIcon('caretRight', size: 16, color: cs.onSurface.withAlpha(140)),
            onTap: () => Navigator.pushNamed(context, AppRoutes.recycleBin),
          ),
    ];
  }

  List<Widget> _backupChildren(ColorScheme cs) {
    return <Widget>[
      // All backup lives here now: the old separate "Add to CipherNest" page
      // folded into this one section. The switch runs the full setup
      // (permissions, "from now" watermark, album choice) when turned on.
      SwitchListTile(
            secondary: ThemeIcon('autoRenew', color: cs.primary),
            title: Text('Auto-back up new photos',
                style: TextStyle(color: cs.onSurface)),
            subtitle: Text(
              _autoSyncEnabled
                  ? '$_backupScope · last sync: $_lastSyncDisplay'
                  : 'Encrypt new photos automatically as you take them',
              style: TextStyle(color: cs.onSurface.withAlpha(140)),
            ),
            value: _autoSyncEnabled,
            onChanged: _toggleAutoSync,
          ),
      if (_autoSyncEnabled) ...[
            ListTile(
              leading: ThemeIcon('checklist', color: cs.primary),
              title: Text('Change which albums',
                  style: TextStyle(color: cs.onSurface)),
              subtitle: Text(
                'Currently backing up: $_backupScope',
                style:
                    TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 12),
              ),
              trailing:
                  ThemeIcon('caretRight', size: 16, color: cs.onSurface),
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const BackupAlbumsScreen()),
                );
                if (mounted) _loadPreferences();
              },
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
                leading: ThemeIcon('calendarClock', color: cs.primary),
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
                leading: ThemeIcon('event', color: cs.primary),
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
                  leading: ThemeIcon('syncProblem', color: cs.primary),
                  title: Text('Background sync being killed?',
                      style: TextStyle(color: cs.onSurface)),
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
              leading: ThemeIcon('sync', color: cs.primary),
              title: Text('Sync now', style: TextStyle(color: cs.onSurface)),
              subtitle: Text('Manually check for new photos right now', style: TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 12)),
              onTap: _handleSyncNow,
            ),
          ],
      ListTile(
            leading: ThemeIcon('cloudArrowUp', color: cs.primary),
            title: Text('Vault index backup',
                style: TextStyle(color: cs.onSurface)),
            subtitle: Text(
                'Upload an encrypted copy of your vault index so a new device '
                'can restore it',
                style: TextStyle(color: cs.onSurface.withAlpha(140))),
            trailing: ThemeIcon('caretRight',
                size: 16, color: cs.onSurface.withAlpha(140)),
            onTap: _handleBackup,
          ),
    ];
  }

  List<Widget> _galleryChildren(ColorScheme cs) {
    const icons = <String, String>{
      GalleryPrefs.kShowYearAgo: 'clockCounterClockwise',
      GalleryPrefs.kShowOnThisDay: 'clockCounterClockwise',
      GalleryPrefs.kShowToday: 'sparkle',
      GalleryPrefs.kShowLastMonth: 'images',
      GalleryPrefs.kShowBestOf: 'heart',
      GalleryPrefs.kShowFeaturedVideo: 'videoCamera',
    };
    final muted = cs.onSurface.withAlpha(140);
    return <Widget>[
      // Master switch: everything on the Stories tab hangs off it.
      SwitchListTile(
            secondary: ThemeIcon('sparkle', color: cs.primary),
            title: Text('Show featured content', style: TextStyle(color: cs.onSurface)),
            subtitle: Text('Stories and memories on the Stories tab',
                style: TextStyle(color: muted)),
            value: _showFeatured,
            onChanged: _toggleFeatured,
          ),
      // The per-kind switches exist only while the master is on.
      if (_showFeatured) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('Stories to show',
              style: TextStyle(
                  color: cs.onSurface, fontWeight: FontWeight.w600)),
        ),
        for (final k in GalleryPrefs.subKinds)
          SwitchListTile(
            secondary: ThemeIcon(icons[k.$1] ?? 'images', color: cs.primary),
            title: Text(k.$2, style: TextStyle(color: cs.onSurface)),
            subtitle: Text(k.$3, style: TextStyle(color: muted)),
            value: _storyFlags[k.$1] ?? true,
            onChanged: (v) => _setStoryFlag(k.$1, v),
          ),
      ],
    ];
  }

  List<Widget> _appearanceChildren(ColorScheme cs) {
    return <Widget>[
      ListenableBuilder(
            listenable: ThemeController(),
            builder: (context, _) {
              final tc = ThemeController();
              return Column(
                children: [
                  ListTile(
                    title: Text('Appearance mode',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface)),
                    trailing: _ThemeModeButton(
                      mode: tc.mode,
                      onCycle: (pos) => ThemeReveal.run(
                        context: context,
                        center: pos,
                        apply: () => tc.setMode(_nextThemeMode(tc.mode)),
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
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: _ThemePackCarousel(
                      current: tc.pack,
                      onPick: tc.setPack,
                    ),
                  ),
                ],
              );
            },
          ),
    ];
  }

  List<Widget> _securityChildren(ColorScheme cs) {
    final muted = cs.onSurface.withAlpha(140);
    return <Widget>[
      // The password decision comes first: it is what the lock, the
      // fingerprint and the phrase check below all depend on.
      if (_passwordlessVault)
        ListTile(
          leading: ThemeIcon('password', color: cs.primary),
          title: Text('Add password', style: TextStyle(color: cs.onSurface)),
          subtitle: Text('Ask for a password every time the vault opens',
              style: TextStyle(color: muted)),
          trailing: ThemeIcon('caretRight', size: 16, color: muted),
          onTap: () => Navigator.pushNamed(context, AppRoutes.addPassword)
              .then((_) => _loadBiometricState()),
        )
      else
        ListTile(
          leading: ThemeIcon('password', color: cs.primary),
          title: Text('Change password', style: TextStyle(color: cs.onSurface)),
          subtitle: Text(
              'Set a new master password (your recovery phrase stays the same)',
              style: TextStyle(color: muted)),
          trailing: ThemeIcon('caretRight', size: 16, color: muted),
          onTap: () => Navigator.pushNamed(context, AppRoutes.changePassword),
        ),
      // Vaults created or restored since view-phrase shipped keep their
      // words (password-wrapped, or beside the seed when there is no
      // password); older ones cannot reveal them, so the tile hides.
      FutureBuilder<bool>(
        future: KeyManagerService().canRevealMnemonic(),
        builder: (context, snap) {
          if (snap.data != true) return const SizedBox.shrink();
          return ListTile(
            leading: ThemeIcon('shieldCheck', color: cs.primary),
            title: Text('View recovery phrase',
                style: TextStyle(color: cs.onSurface)),
            subtitle: Text(
                _passwordlessVault
                    ? 'Show your 12 words'
                    : 'Show your 12 words after a password check',
                style: TextStyle(color: muted)),
            trailing: ThemeIcon('caretRight', size: 16, color: muted),
            onTap: () => Navigator.pushNamed(context, AppRoutes.viewPhrase),
          );
        },
      ),
      // Manual lock (MASVS F-32) and auto-lock. A passwordless vault has no
      // lock screen, so neither applies there.
      if (!_passwordlessVault)
        ListTile(
          leading: ThemeIcon('lock', color: cs.primary),
          title: Text('Lock vault now', style: TextStyle(color: cs.onSurface)),
          subtitle: Text('Close the vault and return to the unlock screen',
              style: TextStyle(color: muted)),
          onTap: () => AppLockService().lockNow(),
        ),
      if (!_passwordlessVault)
        ListTile(
          leading: ThemeIcon('lock', color: cs.primary),
          title: Text('Auto-lock', style: TextStyle(color: cs.onSurface)),
          subtitle: Text(_autoLockLabel(_autoLockMinutes),
              style: TextStyle(color: muted)),
          trailing: ThemeIcon('caretRight', size: 16, color: muted),
          onTap: _pickAutoLock,
        ),
      // Hidden outright when the device can never support it (no sensor /
      // no lock screen): an impossible toggle is worse than none.
      if (!_passwordlessVault &&
          _bioCapability != BiometricCapability.noHardware &&
          _bioCapability != BiometricCapability.noLockScreen)
        SwitchListTile(
          secondary: ThemeIcon('fingerprint', color: cs.primary),
          title: Text('Unlock with fingerprint',
              style: TextStyle(color: cs.onSurface)),
          subtitle: Text(
            _bioSubtitleOverride ??
                (_bioCapability == BiometricCapability.noneEnrolled
                    ? 'No fingerprints enrolled. Add one in Android Settings'
                    : 'Hardware-backed. Your master password always works.'),
            style: TextStyle(color: muted),
          ),
          value: _bioEnabled,
          onChanged: _bioCapability == BiometricCapability.available
              ? _toggleBiometric
              : null,
        ),
      ListTile(
        leading: ThemeIcon('key', color: cs.primary),
        title: Text('Key Management', style: TextStyle(color: cs.onSurface)),
        subtitle: Text('Check encryption integrity',
            style: TextStyle(color: muted)),
        trailing: ThemeIcon('caretRight', size: 16, color: muted),
        onTap: () => Navigator.pushNamed(context, AppRoutes.keyManagement),
      ),
      ListTile(
        leading: ThemeIcon('heart', color: cs.primary),
        title: Text('Vault Health', style: TextStyle(color: cs.onSurface)),
        subtitle: Text(_vaultHealthSubtitle(cs),
            style: TextStyle(color: muted)),
        trailing: _vaultHealthScanning
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : ThemeIcon('caretRight', size: 16, color: muted),
        onTap: _vaultHealthScanning ? null : _runVaultHealthScan,
      ),
      ListTile(
        leading: ThemeIcon('smartphone', color: cs.primary),
        title: Text('Devices', style: TextStyle(color: cs.onSurface)),
        subtitle: Text('Name this device, see others on your vault',
            style: TextStyle(color: muted)),
        trailing: ThemeIcon('caretRight', size: 16, color: muted),
        onTap: _openDevices,
      ),
      // Storage cleanup for blobs sealed under a PREVIOUS vault key (kept
      // during a "start over"). Hidden while there are none.
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
                style: TextStyle(color: muted)),
            trailing: ThemeIcon('caretRight', size: 16, color: muted),
            onTap: () => _cleanupPriorKeyFiles(rows),
          );
        },
      ),
      ListTile(
        leading: ThemeIcon('linkSimple', color: cs.primary),
        title: Text('Active Shares', style: TextStyle(color: cs.onSurface)),
        subtitle: Text('Manage and revoke share links',
            style: TextStyle(color: muted)),
        trailing: ThemeIcon('caretRight', size: 16, color: muted),
        onTap: () => Navigator.pushNamed(context, AppRoutes.activeShares),
      ),
      ListTile(
        leading: ThemeIcon('signOut', color: cs.primary),
        title: Text('Forget this vault on this device',
            style: TextStyle(color: cs.onSurface)),
        subtitle: Text(
            'Remove keys, index, and caches here. Cloud files stay; '
            'your recovery phrase gets you back in.',
            style: TextStyle(color: muted)),
        trailing: ThemeIcon('caretRight', size: 16, color: muted),
        onTap: _forgetVaultOnDevice,
      ),
    ];
  }

  /// Playback settings, out of Security: they are about how music behaves,
  /// and the Music tab links straight here.
  List<Widget> _musicChildren(ColorScheme cs) {
    final muted = cs.onSurface.withAlpha(140);
    return <Widget>[
      // Closing the app should close the vault. The exception is deliberate
      // background playback, which needs the process to outlive the task,
      // so it is opt-in rather than assumed (MASVS F-34).
      SwitchListTile(
        secondary: ThemeIcon('musicNotes', color: cs.primary),
        title: Text('Keep playing after closing',
            style: TextStyle(color: cs.onSurface)),
        subtitle: Text(
          _passwordlessVault
              ? (_keepPlayingOnClose
                  ? 'Music keeps playing after you close the app'
                  : 'Closing the app stops the music')
              : _keepPlayingOnClose
                  ? 'Music survives closing the app and auto-lock. Lock '
                      'vault now always stops it'
                  : 'Closing the app or clearing it from recents locks '
                      'the vault',
          style: TextStyle(color: muted),
        ),
        value: _keepPlayingOnClose,
        onChanged: (v) async {
          await AppLockService().setKeepPlayingOnClose(v);
          if (mounted) _setState(() => _keepPlayingOnClose = v);
        },
      ),
      // Off by default (MASVS F-18): the media notification is visible to
      // anyone holding the phone.
      AnimatedBuilder(
        animation: AudioPlayerService(),
        builder: (context, _) => SwitchListTile(
          secondary: ThemeIcon('lock', color: cs.primary),
          title: Text('Track titles in the media notification',
              style: TextStyle(color: cs.onSurface)),
          subtitle: Text(
            AudioPlayerService().showTitlesOnLockScreen
                ? 'Shows what is playing, on the lock screen too'
                : 'Shows "CipherNest Audio" instead of the title',
            style: TextStyle(color: muted),
          ),
          value: AudioPlayerService().showTitlesOnLockScreen,
          onChanged: (v) => AudioPlayerService().setShowTitlesOnLockScreen(v),
        ),
      ),
    ];
  }

  List<Widget> _aboutChildren(ColorScheme cs) {
    final muted = cs.onSurface.withAlpha(150);
    return <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(28, 20, 28, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const CiphernestLogo(fontSize: 30),
            const SizedBox(height: 8),
            Text(kAppVersionLabel,
                style: TextStyle(color: cs.onSurface.withAlpha(90))),
            const SizedBox(height: 22),
            Text(
              'CipherNest turns your cloud into a zero-knowledge vault. Photos, '
              'videos and files are encrypted on your device with AES-256 '
              'before they ever reach your cloud, so the provider only ever '
              'stores ciphertext and the keys never leave your phone.',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted, fontSize: 13, height: 1.55),
            ),
            const SizedBox(height: 14),
            Text(
              'CipherNest took more than a year to build.\n'
              'Hope you find it worth your while.',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted, fontSize: 13, height: 1.55),
            ),
            const SizedBox(height: 10),
            Text(
              'USMAN',
              style: TextStyle(
                fontFamily: 'BungeeHairline',
                color: cs.onSurface.withAlpha(200),
                fontSize: 13,
                letterSpacing: 3,
              ),
            ),
            const SizedBox(height: 22),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                _aboutLink(ThemeIcon('globe', size: 16, color: cs.primary),
                    'Website', 'https://ciphernest.io'),
                _aboutLink(_brandSvg('linkedin', cs), 'LinkedIn',
                    'https://www.linkedin.com/in/usmanshafs'),
                _aboutLink(_brandSvg('github', cs), 'GitHub',
                    'https://ciphernest.io/source'),
                _aboutLink(_brandSvg('gitlab', cs), 'GitLab',
                    'https://gitlab.com/ciphernest-io'),
              ],
            ),
          ],
        ),
      ),
    ];
  }

  /// A monochrome brand mark (Simple Icons SVG) tinted to the theme.
  Widget _brandSvg(String name, ColorScheme cs) {
    return SvgPicture.asset(
      'assets/images/brands/$name.svg',
      width: 15,
      height: 15,
      colorFilter: ColorFilter.mode(cs.primary, BlendMode.srcIn),
    );
  }

  Widget _aboutLink(Widget icon, String label, String url) {
    final cs = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: () => _openExternal(url),
      icon: icon,
      label: Text(label, style: TextStyle(color: cs.onSurface)),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: cs.outline),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      ),
    );
  }

  Future<void> _openExternal(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      Notify.error('Could not open $url');
    }
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: cs.primary.withAlpha(30),
        child: ThemeIcon(icon, color: cs.primary, size: 22),
      ),
      title: Text(title,
          style: TextStyle(
              color: cs.onSurface,
              fontWeight: FontWeight.w600,
              fontSize: 16)),
      subtitle: Text(subtitle,
          style: TextStyle(color: cs.onSurface.withAlpha(140))),
      trailing: ThemeIcon('caretRight',
          size: 16, color: cs.onSurface.withAlpha(140)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      onTap: onTap,
    );
  }
}

/// The next mode in the cycle: light -> dark -> system -> light.
AppThemeMode _nextThemeMode(AppThemeMode m) => switch (m) {
      AppThemeMode.light => AppThemeMode.dark,
      AppThemeMode.dark => AppThemeMode.system,
      AppThemeMode.system => AppThemeMode.light,
    };

/// The current-mode icon as a tappable chip. Tapping reports the tap point so
/// the theme-change circle reveal springs from the icon itself. Icons: sun,
/// moon, and settings_system_daydream (the OS "system default" mark).
class _ThemeModeButton extends StatelessWidget {
  const _ThemeModeButton({required this.mode, required this.onCycle});

  final AppThemeMode mode;
  final void Function(Offset globalPosition) onCycle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final icon = switch (mode) {
      AppThemeMode.light => 'sun',
      AppThemeMode.dark => 'moon',
      AppThemeMode.system => 'systemTheme',
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) => onCycle(d.globalPosition),
      child: Padding(
        // No background plate; the icon fill follows the active theme pack
        // rather than being forced on.
        padding: const EdgeInsets.all(8),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, anim) => ScaleTransition(
            scale: anim,
            child: FadeTransition(opacity: anim, child: child),
          ),
          child: ThemeIcon(icon,
              key: ValueKey(icon), size: 26, color: cs.primary),
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

/// The theme-pack picker: shows the first few packs, with a button to expand
/// the rest and collapse again. The selected pack is always kept visible.
/// The theme picker: a horizontal carousel with the chosen pack centred at
/// full size and its neighbours peeking in from both sides, smaller and
/// faded. Swiping a pack into the centre applies it; tapping a neighbour
/// swipes it in. No tick: being in view IS the selection.
class _ThemePackCarousel extends StatefulWidget {
  const _ThemePackCarousel({required this.current, required this.onPick});

  final ThemePack current;
  final ValueChanged<ThemePack> onPick;

  @override
  State<_ThemePackCarousel> createState() => _ThemePackCarouselState();
}

class _ThemePackCarouselState extends State<_ThemePackCarousel> {
  static const _packs = ThemePack.values;
  late final PageController _ctrl = PageController(
    viewportFraction: 0.9,
    initialPage: _packs.indexOf(widget.current),
  );

  @override
  void didUpdateWidget(covariant _ThemePackCarousel old) {
    super.didUpdateWidget(old);
    if (old.current == widget.current || !_ctrl.hasClients) return;
    final i = _packs.indexOf(widget.current);
    if ((_ctrl.page ?? i).round() != i) _goTo(i);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _goTo(int i) => _ctrl.animateToPage(i,
      duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 118,
      child: PageView.builder(
        controller: _ctrl,
        itemCount: _packs.length,
        onPageChanged: (i) => widget.onPick(_packs[i]),
        itemBuilder: (context, i) => AnimatedBuilder(
          animation: _ctrl,
          builder: (context, child) {
            final settled = _ctrl.hasClients &&
                _ctrl.position.hasContentDimensions;
            final page = settled
                ? (_ctrl.page ?? i.toDouble())
                : _packs.indexOf(widget.current).toDouble();
            final d = (page - i).abs().clamp(0.0, 1.0);
            return Transform.scale(
              scale: 1 - 0.12 * d,
              child: Opacity(opacity: 1 - 0.5 * d, child: child),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: _ThemePackTile(
              pack: _packs[i],
              selected: _packs[i] == widget.current,
              onTap: () => _goTo(i),
            ),
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
                        ],
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
                    // The ORIGINAL pack photo (assets/images/): this is a
                    // preview with no text over it, so it never uses the
                    // mode-tinted card art.
                    'assets/images/'
                        '${pack == ThemePack.hackerman ? 'hacker' : pack.name}'
                        '.webp',
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
                  'references. Nothing is deleted automatically. A future '
                  'update will let you recover or remove these.'),
            ],
            if (report.missingBlobFileIds.isNotEmpty) ...[
              _row(cs, 'warningCircle',
                  '${report.missingBlobFileIds.length} missing file'
                  '${report.missingBlobFileIds.length == 1 ? '' : 's'}',
                  'Files the app expects but whose encrypted data is gone '
                  'from your cloud, likely deleted in the cloud\'s own web '
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
  final ValueListenable<List<KnownDevice>> devices;
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
                          await widget.onRename(_name.text.trim());
                          // Stay open: the list below updates in place.
                          if (!mounted) return;
                          setState(() => _saving = false);
                          Notify.info('Name saved');
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
            ValueListenableBuilder<List<KnownDevice>>(
              valueListenable: widget.devices,
              builder: (context, devices, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (devices.isEmpty)
                    Text('Only this device so far.',
                        style:
                            TextStyle(color: cs.onSurface.withAlpha(140))),
                  for (final d in devices)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: ThemeIcon(
                          d.isThisDevice ? 'smartphone' : 'cloudArrowDown',
                          color: cs.primary),
                      title:
                          Text(d.name, style: TextStyle(color: cs.onSurface)),
                      subtitle: d.isThisDevice
                          ? Text('This device',
                              style: TextStyle(
                                  color: cs.onSurface.withAlpha(140)))
                          : null,
                    ),
                ],
              ),
            ),
          ],
          ),
        ),
      ),
    );
  }
}
