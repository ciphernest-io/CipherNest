import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart'; // ENABLED
import '../../config/routes.dart';
import '../../config/theme.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/database_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/cache_manager_service.dart';
import '../../../services/auto_sync_service.dart';
import 'package:permission_handler/permission_handler.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _cacheSize = "Calculating...";
  double _cacheLimitGB = 0.5;    // The value the slider shows NOW
  double _originalLimitGB = 0.5; // The value saved on DISK
  
  // Storage Stats
  int _totalFileCount = 0;
  int _imageBytes = 0;
  int _docBytes = 0;
  bool _isLoading = true;
  bool get _hasChanges => _cacheLimitGB != _originalLimitGB;

  // Auto-Sync
  bool _autoSyncEnabled = false;
  String _lastSyncDisplay = 'Never';

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

    final stats = await DatabaseService().getStorageStats();

    if (mounted) {
      setState(() {
        _cacheSize = _formatBytes(cacheBytes);
        _imageBytes = stats['images'] ?? 0;
        _docBytes = stats['docs'] ?? 0;
        _totalFileCount = stats['total_count'] ?? 0;
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

  Future<void> _handleSignOut() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign Out?'),
        content: const Text('You will need to reconnect your Google Drive to access your files.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true), 
            child: const Text('Sign Out', style: TextStyle(color: Colors.red))
          ),
        ],
      ),
    );

    if (confirm == true) {
      await CloudService().signOut();
      if (mounted) {
        Navigator.pushNamedAndRemoveUntil(context, AppRoutes.home, (route) => false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = CloudService().currentEmail ?? 'Not Connected';
    final totalBytes = _imageBytes + _docBytes;
    final totalForBar = totalBytes == 0 ? 1 : totalBytes; 
    final imageFlex = (_imageBytes / totalForBar * 100).round();
    final docFlex = (_docBytes / totalForBar * 100).round();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // ... Account Section ...
          _SectionHeader(title: "Account"),
          ListTile(
            leading: const CircleAvatar(backgroundColor: Colors.purpleAccent, child: Icon(Icons.person, color: Colors.white)),
            title: Text(email, style: const TextStyle(color: Colors.white)),
            subtitle: const Text('Google Drive Connected', style: TextStyle(color: Colors.grey)),
            trailing: IconButton(icon: const Icon(Icons.logout, color: Colors.redAccent), onPressed: _handleSignOut),
          ),
          const Divider(color: Colors.white10),

          // ... Storage Bar Section ...
          _SectionHeader(title: "Vault Usage"),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white10)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_formatBytes(totalBytes), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
                    Text("$_totalFileCount Files", style: const TextStyle(color: Colors.grey)),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    height: 12,
                    child: Row(
                      children: [
                        if (totalBytes > 0) ...[
                          Flexible(flex: imageFlex, child: Container(color: Colors.purpleAccent)),
                          Flexible(flex: docFlex, child: Container(color: Colors.blueAccent)),
                        ] else 
                          Flexible(flex: 1, child: Container(color: Colors.grey[800])),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(children: [
                  _LegendItem(color: Colors.purpleAccent, label: "Photos", size: _imageBytes),
                  const SizedBox(width: 24),
                  _LegendItem(color: Colors.blueAccent, label: "Documents", size: _docBytes),
                ]),
              ],
            ),
          ),

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
            leading: const Icon(Icons.cleaning_services, color: Colors.orangeAccent),
            title: const Text('Clear Local Cache', style: TextStyle(color: Colors.white)),
            subtitle: Text('Free up $_cacheSize on device', style: const TextStyle(color: Colors.grey)),
            onTap: _clearCache,
          ),
          ListTile(
            leading: const Icon(Icons.backup, color: Colors.greenAccent),
            title: const Text('Backup Vault Index', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Encrypt and upload your vault index to the cloud', style: TextStyle(color: Colors.grey)),
            onTap: _handleBackup,
          ),
          ListTile(
            leading: const Icon(Icons.photo_library, color: Colors.cyanAccent),
            title: const Text('Migrate Gallery', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Import existing photos into CipherNest', style: TextStyle(color: Colors.grey)),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
            onTap: () => Navigator.pushNamed(context, AppRoutes.migration),
          ),

          const Divider(color: Colors.white10),

          // --- AUTO-SYNC ---
          _SectionHeader(title: "Auto-Sync"),
          SwitchListTile(
            secondary: const Icon(Icons.sync, color: Colors.cyanAccent),
            title: const Text('Auto-Sync Gallery', style: TextStyle(color: Colors.white)),
            subtitle: Text(
              _autoSyncEnabled ? 'Last sync: $_lastSyncDisplay' : 'Automatically encrypt new photos',
              style: const TextStyle(color: Colors.grey),
            ),
            value: _autoSyncEnabled,
            activeColor: Colors.cyanAccent,
            onChanged: _toggleAutoSync,
          ),
          if (_autoSyncEnabled)
            ListTile(
              leading: const SizedBox(width: 24),
              title: const Text('Sync Now', style: TextStyle(color: Colors.cyanAccent)),
              subtitle: const Text('New photos sync automatically on app open', style: TextStyle(color: Colors.grey, fontSize: 12)),
              trailing: const Icon(Icons.play_arrow, color: Colors.cyanAccent),
              onTap: _handleSyncNow,
            ),

          const Divider(color: Colors.white10),
          // ... Security Section ...
          _SectionHeader(title: "Security"),
          ListTile(
            leading: const Icon(Icons.vpn_key, color: Colors.greenAccent),
            title: const Text('Key Management', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Check encryption integrity', style: TextStyle(color: Colors.grey)),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
            onTap: () => Navigator.pushNamed(context, AppRoutes.keyManagement),
          ),
          
          const SizedBox(height: 40),
          const Center(child: Text('CipherNest v0.5.0 Beta', style: TextStyle(color: Colors.white24))),
        ],
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  final int size;

  const _LegendItem({required this.color, required this.label, required this.size});

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
            Text(_formatBytes(size), style: TextStyle(color: Colors.grey[400], fontSize: 10)),
          ],
        )
      ],
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
        style: const TextStyle(
          color: AppColors.primary,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}