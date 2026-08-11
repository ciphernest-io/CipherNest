import 'package:flutter/material.dart';
import '../../widgets/activity_pill.dart';
import '../../widgets/theme_icon.dart';
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

  // Keep the global activity pill above the bottom nav bar.
  late final InsetClaim _pillInset;

  @override
  void initState() {
    super.initState();
    _pillInset = ActivityPillInset.claim(kBottomNavigationBarHeight);
  }

  @override
  void dispose() {
    _pillInset.release();
    super.dispose();
  }

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
          BottomNavigationBarItem(icon: ThemeIcon('image'), label: 'Pictures'),
          BottomNavigationBarItem(
              icon: ThemeIcon('folderSimple'), label: 'Albums'),
          BottomNavigationBarItem(icon: ThemeIcon('clockCounterClockwise'), label: 'Stories'),
          BottomNavigationBarItem(icon: ThemeIcon('list'), label: 'Menu'),
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
          // onPrimary, not onSurface — the glyph sits on the accent disc.
          child: ThemeIcon('lock', color: cs.onPrimary, size: 32),
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
          leading: ThemeIcon('gear', color: cs.onSurface.withAlpha(120)),
          title: Text('Settings', style: TextStyle(color: cs.onSurface)),
          trailing:
              ThemeIcon('caretRight', size: 16, color: cs.onSurface.withAlpha(120)),
          onTap: () => Navigator.pushNamed(context, AppRoutes.settings),
        ),
        ListTile(
          leading: ThemeIcon('key', color: cs.onSurface.withAlpha(120)),
          title: Text('Key Management',
              style: TextStyle(color: cs.onSurface)),
          trailing:
              ThemeIcon('caretRight', size: 16, color: cs.onSurface.withAlpha(120)),
          onTap: () => Navigator.pushNamed(context, AppRoutes.keyManagement),
        ),
        ListTile(
          leading: ThemeIcon('images', color: cs.onSurface.withAlpha(120)),
          title: Text('Migrate Gallery',
              style: TextStyle(color: cs.onSurface)),
          trailing:
              ThemeIcon('caretRight', size: 16, color: cs.onSurface.withAlpha(120)),
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
