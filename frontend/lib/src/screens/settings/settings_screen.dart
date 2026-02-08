import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../../config/routes.dart';
import '../../config/theme.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/database_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _cacheSize = "Calculating...";
  
  // Storage Stats
  int _totalFileCount = 0;
  int _imageBytes = 0;
  int _docBytes = 0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    // 1. Cache Size
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

    // 2. Database Stats (The Color Bar Data)
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

  Future<void> _handleSignOut() async {
    // ... (Keep existing sign out logic) ...
    // (If you need me to paste it again, let me know!)
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
    
    // Avoid division by zero for the bar
    final totalForBar = totalBytes == 0 ? 1 : totalBytes; 
    final imageFlex = (_imageBytes / totalForBar * 100).round();
    final docFlex = (_docBytes / totalForBar * 100).round();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // --- SECTION: ACCOUNT ---
          _SectionHeader(title: "Account"),
          ListTile(
            leading: const CircleAvatar(
              backgroundColor: Colors.purpleAccent,
              child: Icon(Icons.person, color: Colors.white),
            ),
            title: Text(email, style: const TextStyle(color: Colors.white)),
            subtitle: const Text('Google Drive Connected', style: TextStyle(color: Colors.grey)),
            trailing: IconButton(
              icon: const Icon(Icons.logout, color: Colors.redAccent),
              onPressed: _handleSignOut,
            ),
          ),

          const Divider(color: Colors.white10),

          // --- SECTION: STORAGE BAR ---
          _SectionHeader(title: "Vault Usage"),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white10),
            ),
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
                
                // THE BAR
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
                
                // LEGEND
                Row(
                  children: [
                    _LegendItem(color: Colors.purpleAccent, label: "Photos", size: _imageBytes),
                    const SizedBox(width: 24),
                    _LegendItem(color: Colors.blueAccent, label: "Documents", size: _docBytes),
                  ],
                ),
              ],
            ),
          ),

          // --- SECTION: DATA ---
          _SectionHeader(title: "Data Management"),
          ListTile(
            leading: const Icon(Icons.cleaning_services, color: Colors.orangeAccent),
            title: const Text('Clear Local Cache', style: TextStyle(color: Colors.white)),
            subtitle: Text('Free up $_cacheSize on device', style: const TextStyle(color: Colors.grey)),
            onTap: _clearCache,
          ),

          const Divider(color: Colors.white10),

          // --- SECTION: SECURITY ---
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

// Helper Widget for the Legend
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