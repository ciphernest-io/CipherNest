import 'package:flutter/material.dart';
import '../../config/theme.dart';
import '../../config/routes.dart';
import 'pictures_tab.dart';
import 'albums_tab.dart';
import 'stories_tab.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  int _bottomNavIndex = 0;
  final _picturesKey = GlobalKey<PicturesTabState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_tabTitle),
        elevation: 0,
      ),
      body: IndexedStack(
        index: _bottomNavIndex,
        children: [
          PicturesTab(key: _picturesKey),
          const AlbumsTab(),
          const StoriesTab(),
          _buildMenuTab(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        selectedItemColor: AppColors.primary,
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
        currentIndex: _bottomNavIndex,
        onTap: (index) => setState(() => _bottomNavIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.photo), label: 'Pictures'),
          BottomNavigationBarItem(
              icon: Icon(Icons.photo_album), label: 'Albums'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: 'Stories'),
          BottomNavigationBarItem(icon: Icon(Icons.menu), label: 'Menu'),
        ],
      ),
    );
  }

  String get _tabTitle {
    switch (_bottomNavIndex) {
      case 0:
        return 'Encrypted Gallery';
      case 1:
        return 'Albums';
      case 2:
        return 'Stories';
      case 3:
        return 'Menu';
      default:
        return 'Gallery';
    }
  }

  Widget _buildMenuTab() {
    return ListView(
      children: [
        const SizedBox(height: 32),
        const CircleAvatar(
          radius: 36,
          backgroundColor: Colors.purpleAccent,
          child: Icon(Icons.lock, color: Colors.white, size: 32),
        ),
        const SizedBox(height: 16),
        const Center(
          child: Text('CipherNest',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 32),
        ListTile(
          leading: const Icon(Icons.settings, color: Colors.grey),
          title: const Text('Settings', style: TextStyle(color: Colors.white)),
          trailing:
              const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
          onTap: () => Navigator.pushNamed(context, AppRoutes.settings),
        ),
        ListTile(
          leading: const Icon(Icons.vpn_key, color: Colors.grey),
          title: const Text('Key Management',
              style: TextStyle(color: Colors.white)),
          trailing:
              const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
          onTap: () => Navigator.pushNamed(context, AppRoutes.keyManagement),
        ),
        ListTile(
          leading: const Icon(Icons.photo_library, color: Colors.grey),
          title: const Text('Migrate Gallery',
              style: TextStyle(color: Colors.white)),
          trailing:
              const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
          onTap: () => Navigator.pushNamed(context, AppRoutes.migration),
        ),
        const SizedBox(height: 40),
        const Center(
            child: Text('CipherNest v0.5.0 Beta',
                style: TextStyle(color: Colors.white24))),
      ],
    );
  }
}
