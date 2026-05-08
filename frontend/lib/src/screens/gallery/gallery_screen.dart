import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
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
        type: BottomNavigationBarType.fixed,
        currentIndex: _bottomNavIndex,
        onTap: (index) => setState(() => _bottomNavIndex = index),
        items: [
          BottomNavigationBarItem(icon: Icon(PhosphorIcons.image(PhosphorIconsStyle.thin)), label: 'Pictures'),
          BottomNavigationBarItem(
              icon: Icon(PhosphorIcons.folderSimple(PhosphorIconsStyle.thin)), label: 'Albums'),
          BottomNavigationBarItem(icon: Icon(PhosphorIcons.clockCounterClockwise(PhosphorIconsStyle.thin)), label: 'Stories'),
          BottomNavigationBarItem(icon: Icon(PhosphorIcons.list(PhosphorIconsStyle.thin)), label: 'Menu'),
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
    final cs = Theme.of(context).colorScheme;
    return ListView(
      children: [
        const SizedBox(height: 32),
        CircleAvatar(
          radius: 36,
          backgroundColor: cs.primary,
          child: Icon(PhosphorIcons.lock(PhosphorIconsStyle.thin), color: cs.onSurface, size: 32),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text('CipherNest',
              style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 20,
                  fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 32),
        ListTile(
          leading: Icon(PhosphorIcons.gear(PhosphorIconsStyle.thin), color: cs.onSurface.withAlpha(120)),
          title: Text('Settings', style: TextStyle(color: cs.onSurface)),
          trailing:
              Icon(PhosphorIcons.caretRight(PhosphorIconsStyle.thin), size: 16, color: cs.onSurface.withAlpha(120)),
          onTap: () => Navigator.pushNamed(context, AppRoutes.settings),
        ),
        ListTile(
          leading: Icon(PhosphorIcons.key(PhosphorIconsStyle.thin), color: cs.onSurface.withAlpha(120)),
          title: Text('Key Management',
              style: TextStyle(color: cs.onSurface)),
          trailing:
              Icon(PhosphorIcons.caretRight(PhosphorIconsStyle.thin), size: 16, color: cs.onSurface.withAlpha(120)),
          onTap: () => Navigator.pushNamed(context, AppRoutes.keyManagement),
        ),
        ListTile(
          leading: Icon(PhosphorIcons.images(PhosphorIconsStyle.thin), color: cs.onSurface.withAlpha(120)),
          title: Text('Migrate Gallery',
              style: TextStyle(color: cs.onSurface)),
          trailing:
              Icon(PhosphorIcons.caretRight(PhosphorIconsStyle.thin), size: 16, color: cs.onSurface.withAlpha(120)),
          onTap: () => Navigator.pushNamed(context, AppRoutes.migration),
        ),
        const SizedBox(height: 40),
        Center(
            child: Text('CipherNest v0.5.0 Beta',
                style: TextStyle(color: cs.onSurface.withAlpha(60)))),
      ],
    );
  }
}
