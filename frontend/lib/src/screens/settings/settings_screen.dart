import 'dart:io';
import 'package:flutter/material.dart';
import '../../widgets/theme_icon.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart'; // ENABLED
import '../../config/routes.dart';
import '../../config/theme.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/cloud/account_registry.dart';
import '../../../services/cloud/cloud_account.dart';
import '../../../services/database_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/cache_manager_service.dart';
import '../../../services/auto_sync_service.dart';
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
  double _cacheLimitGB = 0.5;    // The value the slider shows NOW
  double _originalLimitGB = 0.5; // The value saved on DISK
  
  bool _isLoading = true;
  bool get _hasChanges => _cacheLimitGB != _originalLimitGB;

  // Auto-Sync
  bool _autoSyncEnabled = false;
  String _lastSyncDisplay = 'Never';

  // Gallery
  bool _showFeatured = true;
  bool _showYearAgo = true;

  @override
  void initState() {
    super.initState();
    _loadStats();
    _loadPreferences(); // ENABLED
  }

  // --- NEW: PERSISTENCE LOGIC ---
  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      final lastRunMs = prefs.getInt('auto_sync_last_run') ?? 0;
      setState(() {
        final val = prefs.getDouble('cache_limit') ?? 0.5;
        _cacheLimitGB = val;
        _originalLimitGB = val;
        _autoSyncEnabled = prefs.getBool('auto_sync_enabled') ?? false;
        _showFeatured = prefs.getBool('gallery_show_featured') ?? true;
        _showYearAgo = prefs.getBool('gallery_show_year_ago') ?? true;
        if (lastRunMs > 0) {
          final dt = DateTime.fromMillisecondsSinceEpoch(lastRunMs);
          _lastSyncDisplay = '${dt.month}/${dt.day} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
        }
      });
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cache limit saved & applied')));
      _loadStats(); // Reload stats to show freed space
    }
  }

  Future<void> _loadStats() async {
    final tempDir = await getTemporaryDirectory();
    int cacheBytes = 0;
    try {
      if (await tempDir.exists()) {
        await for (var file in tempDir.list(recursive: true, followLinks: false)) {
          if (file is File) {
            cacheBytes += await file.length();
          }
        }
      }
    } catch (e) {
      debugPrint("Cache error: $e");
    }

    if (mounted) {
      setState(() {
        _cacheSize = _formatBytes(cacheBytes);
        _isLoading = false;
      });
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
  }

  Future<void> _clearCache() async {
    final tempDir = await getTemporaryDirectory();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
      await tempDir.create();
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cache cleared')));
      _loadStats();
    }
  }

  Future<void> _handleBackup() async {
    setState(() => _isLoading = true);
    try {
      await DatabaseBackupService().backupDatabase();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Vault index backed up successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Backup failed: $e'), backgroundColor: Colors.red),
        );
      }
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
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Media permissions are required for auto-sync')),
          );
        }
        return;
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_sync_enabled', enabled);
    if (enabled) {
      // Set watermark to NOW — only photos taken after this moment auto-sync.
      // Existing gallery photos require the Migration feature instead.
      await prefs.setInt(
        'auto_sync_watermark',
        DateTime.now().millisecondsSinceEpoch,
      );
    }
    if (mounted) setState(() => _autoSyncEnabled = enabled);
  }

  Future<void> _handleSyncNow() async {
    setState(() => _isLoading = true);
    try {
      final result = await AutoSyncService().runFullSync();
      if (mounted) {
        final msg = result.synced > 0
            ? '${result.synced} photo${result.synced == 1 ? '' : 's'} secured'
            : 'No new photos found';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        _loadPreferences();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sync failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _toggleFeatured(bool val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('gallery_show_featured', val);
    if (mounted) setState(() => _showFeatured = val);
  }

  Future<void> _toggleYearAgo(bool val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('gallery_show_year_ago', val);
    if (mounted) setState(() => _showYearAgo = val);
  }

  IconData _providerIcon(int providerType) {
    switch (providerType) {
      case CloudAccount.providerGoogle:
        return themeIconData('googleLogo');
      case CloudAccount.providerOneDrive:
        return themeIconData('microsoftOutlookLogo');
      case CloudAccount.providerDropbox:
        return themeIconData('dropboxLogo');
      default:
        return themeIconData('cloud');
    }
  }

  Future<void> _handleRemoveAccount(String accountId) async {
    final accounts = AccountRegistry().accounts;
    final account = accounts.firstWhere((a) => a.id == accountId);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Sign out of ${account.email}?'),
        content: Text('Files on ${account.providerName} stay there. You can sign back in anytime.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign Out', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final wasActive = AccountRegistry().activeAccount?.id == accountId;
    await AccountRegistry().removeAccount(accountId);
    CloudService().reset();

    if (wasActive) {
      final newActive = AccountRegistry().activeAccount;
      if (newActive != null) {
        DatabaseService().setCurrentAccount(newActive.id);
      } else if (mounted) {
        // No accounts left — back to cloud selection (clean slate)
        Navigator.pushNamedAndRemoveUntil(
            context, AppRoutes.cloudSelection, (r) => false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // --- ACCOUNTS (multi-account) ---
          _SectionHeader(title: "Accounts"),
          ListenableBuilder(
            listenable: AccountRegistry(),
            builder: (context, _) {
              final cs = Theme.of(context).colorScheme;
              final accounts = AccountRegistry().accounts;
              final active = AccountRegistry().activeAccount;
              return Column(
                children: [
                  for (final a in accounts)
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: cs.primary.withAlpha(60),
                        child: Icon(_providerIcon(a.providerType), color: cs.primary, size: 20),
                      ),
                      title: Text(a.email, style: TextStyle(color: cs.onSurface)),
                      subtitle: Text(
                        active?.id == a.id ? '${a.providerName} • Active' : a.providerName,
                        style: TextStyle(color: cs.onSurface.withAlpha(140)),
                      ),
                      trailing: IconButton(
                        icon: ThemeIcon('signOut', color: Colors.redAccent),
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
          const Divider(color: Colors.white10),

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
                    const Text("Max Cache Size", style: TextStyle(color: Colors.white)),
                    // Highlight if unsaved
                    Text(
                      "${_cacheLimitGB.toStringAsFixed(1)} GB", 
                      style: TextStyle(
                        color: _hasChanges ? Colors.orangeAccent : AppColors.primary, 
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
                  activeColor: _hasChanges ? Colors.orangeAccent : AppColors.primary,
                  inactiveColor: Colors.grey[800],
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
                      const Text("Unsaved changes", style: TextStyle(color: Colors.orangeAccent, fontSize: 12)),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: _hasChanges ? _savePreferences : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white, // <--- FORCE TEXT WHITE
                        disabledBackgroundColor: Colors.grey[800],
                        disabledForegroundColor: Colors.grey[500],
                      ),
                      child: const Text("Save & Apply"),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  "Older files will be removed from device when cache exceeds this limit.",
                  style: TextStyle(color: Colors.grey, fontSize: 11),
                ),
              ],
            ),
          ),

          ListTile(
            leading: ThemeIcon('broom', color: Colors.orangeAccent),
            title: const Text('Clear Local Cache', style: TextStyle(color: Colors.white)),
            subtitle: Text('Free up $_cacheSize on device', style: const TextStyle(color: Colors.grey)),
            onTap: _clearCache,
          ),
          ListTile(
            leading: ThemeIcon('cloudArrowUp', color: Colors.greenAccent),
            title: const Text('Backup Vault Index', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Encrypt and upload your vault index to the cloud', style: TextStyle(color: Colors.grey)),
            onTap: _handleBackup,
          ),
          ListTile(
            leading: ThemeIcon('linkSimple', color: Colors.cyanAccent),
            title: const Text('Active Shares', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Manage and revoke share links', style: TextStyle(color: Colors.grey)),
            trailing: ThemeIcon('caretRight', size: 16, color: Colors.grey),
            onTap: () => Navigator.pushNamed(context, AppRoutes.activeShares),
          ),
          ListTile(
            leading: ThemeIcon('images', color: Colors.cyanAccent),
            title: const Text('Migrate Gallery', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Import existing photos into CipherNest', style: TextStyle(color: Colors.grey)),
            trailing: ThemeIcon('caretRight', size: 16, color: Colors.grey),
            onTap: () => Navigator.pushNamed(context, AppRoutes.migration),
          ),
          ListTile(
            leading: ThemeIcon('trash', color: Colors.redAccent),
            title: const Text('Recycle Bin', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Restore or permanently delete recent items', style: TextStyle(color: Colors.grey)),
            trailing: ThemeIcon('caretRight', size: 16, color: Colors.grey),
            onTap: () => Navigator.pushNamed(context, AppRoutes.recycleBin),
          ),

          const Divider(color: Colors.white10),

          // --- AUTO-SYNC ---
          _SectionHeader(title: "Auto-Sync"),
          SwitchListTile(
            secondary: ThemeIcon('arrowsClockwise', color: Colors.cyanAccent),
            title: const Text('Auto-Sync Gallery', style: TextStyle(color: Colors.white)),
            subtitle: Text(
              _autoSyncEnabled ? 'Last sync: $_lastSyncDisplay' : 'Automatically encrypt new photos',
              style: const TextStyle(color: Colors.grey),
            ),
            value: _autoSyncEnabled,
            activeThumbColor: Colors.cyanAccent,
            onChanged: _toggleAutoSync,
          ),
          if (_autoSyncEnabled)
            ListTile(
              leading: const SizedBox(width: 24),
              title: const Text('Sync Now', style: TextStyle(color: Colors.cyanAccent)),
              subtitle: const Text('New photos sync automatically on app open', style: TextStyle(color: Colors.grey, fontSize: 12)),
              trailing: ThemeIcon('play', selected: true, color: Colors.cyanAccent),
              onTap: _handleSyncNow,
            ),

          const Divider(color: Colors.white10),

          // --- GALLERY ---
          _SectionHeader(title: "Gallery"),
          SwitchListTile(
            secondary: ThemeIcon('sparkle', color: Colors.amberAccent),
            title: const Text('Show Featured Content', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Display stories and highlights', style: TextStyle(color: Colors.grey)),
            value: _showFeatured,
            activeThumbColor: Colors.amberAccent,
            onChanged: _toggleFeatured,
          ),
          SwitchListTile(
            secondary: ThemeIcon('clockCounterClockwise', color: Colors.amberAccent),
            title: const Text('A Year Ago Memories', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Show photos from this day last year', style: TextStyle(color: Colors.grey)),
            value: _showYearAgo,
            activeThumbColor: Colors.amberAccent,
            onChanged: _toggleYearAgo,
          ),

          const Divider(color: Colors.white10),

          // --- APPEARANCE ---
          _SectionHeader(title: "Appearance"),
          ListenableBuilder(
            listenable: ThemeController(),
            builder: (context, _) {
              final tc = ThemeController();
              return Column(
                children: [
                  SwitchListTile(
                    secondary: Icon(
                      tc.brightness == Brightness.dark ? themeIconData('moon') : themeIconData('sun'),
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    title: Text('Light Mode', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                    subtitle: Text(
                      tc.brightness == Brightness.dark ? 'Currently dark' : 'Currently light',
                      style: TextStyle(color: Theme.of(context).textTheme.bodyMedium!.color),
                    ),
                    value: tc.brightness == Brightness.light,
                    onChanged: (_) => tc.toggleBrightness(),
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

          const Divider(color: Colors.white10),
          // ... Security Section ...
          _SectionHeader(title: "Security"),
          ListTile(
            leading: ThemeIcon('key', color: Colors.greenAccent),
            title: const Text('Key Management', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Check encryption integrity', style: TextStyle(color: Colors.grey)),
            trailing: ThemeIcon('caretRight', size: 16, color: Colors.grey),
            onTap: () => Navigator.pushNamed(context, AppRoutes.keyManagement),
          ),
          
          const SizedBox(height: 40),
          const Center(child: Text('CipherNest v0.5.0 Beta', style: TextStyle(color: Colors.white24))),
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
          color: AppColors.primary,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

/// One row in the theme-pack picker. Shows the pack name, a one-line tagline,
/// and a swatch trio (bg / surface / accent) so the user can preview the
/// palette before tapping. Tap commits via [onTap].
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
    final cs = Theme.of(context).colorScheme;
    // Preview swatches use the pack's DARK tokens since dark is the design
    // system's default — the user can flip the brightness switch above.
    final t = ThemePackTokens.forPackMode(pack, Brightness.dark);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? cs.surfaceContainerHigh : cs.surfaceContainer,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? cs.primary : cs.outline,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              _SwatchTrio(bg: t.bg, surface: t.surface, accent: t.accent),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pack.label,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      pack.tagline,
                      style: TextStyle(
                        color: cs.onSurface.withAlpha(140),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle, color: cs.primary, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

class _SwatchTrio extends StatelessWidget {
  final Color bg;
  final Color surface;
  final Color accent;
  const _SwatchTrio({
    required this.bg,
    required this.surface,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 36,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _Dot(color: surface),
          const SizedBox(width: 4),
          _Dot(color: accent),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  const _Dot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}