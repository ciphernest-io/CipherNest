import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../../config/routes.dart';
import '../../config/theme.dart';
import '../../../services/drive_service.dart';
import '../../../services/database_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _cacheSize = "Calculing...";
  int _fileCount = 0;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    // 1. Calculate Cache Size
    final tempDir = await getTemporaryDirectory();
    int totalBytes = 0;
    
    try {
      if (await tempDir.exists()) {
        await for (var file in tempDir.list(recursive: true, followLinks: false)) {
          if (file is File) {
            totalBytes += await file.length();
          }
        }
      }
    } catch (e) {
      debugPrint("Cache calc error: $e");
    }

    // 2. Count Encrypted Files
    // We can just query the DB for the count
    final db = await DatabaseService().database;
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM files')
    ) ?? 0;

    if (mounted) {
      setState(() {
        _cacheSize = "${(totalBytes / 1024 / 1024).toStringAsFixed(2)} MB";
        _fileCount = count;
      });
    }
  }

  Future<void> _clearCache() async {
    final tempDir = await getTemporaryDirectory();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true); // Nuke it
      await tempDir.create(); // Recreate the folder
    }
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cache cleared successfully')),
      );
      _loadStats(); // Refresh UI
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
      await DriveService.signOut();
      if (mounted) {
        // Remove all routes and go back to Home (which will show the Login screen)
        Navigator.pushNamedAndRemoveUntil(context, AppRoutes.home, (route) => false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = DriveService.currentEmail ?? 'Not Connected';

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

          // --- SECTION: STORAGE ---
          _SectionHeader(title: "Storage & Data"),
          ListTile(
            leading: const Icon(Icons.cleaning_services, color: Colors.blueAccent),
            title: const Text('Clear Local Cache', style: TextStyle(color: Colors.white)),
            subtitle: Text('Frees up space on your device ($_cacheSize)', style: const TextStyle(color: Colors.grey)),
            onTap: _clearCache,
          ),
          ListTile(
            leading: const Icon(Icons.cloud_done, color: Colors.greenAccent),
            title: const Text('Database Stats', style: TextStyle(color: Colors.white)),
            subtitle: Text('Tracking $_fileCount secure files', style: const TextStyle(color: Colors.grey)),
          ),

          const Divider(color: Colors.white10),

          // --- SECTION: SECURITY ---
          _SectionHeader(title: "Security"),
          ListTile(
            leading: const Icon(Icons.vpn_key, color: Colors.orangeAccent),
            title: const Text('Key Management', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Check encryption integrity', style: TextStyle(color: Colors.grey)),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
            onTap: () => Navigator.pushNamed(context, AppRoutes.keyManagement),
          ),

          const SizedBox(height: 40),
          const Center(
            child: Text(
              'CipherNest v0.5.0 (Beta)',
              style: TextStyle(color: Colors.white24),
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