import 'package:flutter/material.dart';

import '../../config/app_info.dart';
import '../../config/routes.dart';
import '../../widgets/ciphernest_logo.dart';
import '../../widgets/theme_icon.dart';
import '../settings/recycle_bin_screen.dart';
import '../splash/splash_screen.dart';

/// The gallery's "Menu" tab: the CipherNest wordmark over a short list of
/// entry points (Settings, Recycle Bin, Add to CipherNest). Its own widget,
/// like PicturesTab/AlbumsTab/StoriesTab.
class MenuTab extends StatelessWidget {
  const MenuTab({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final safeTop = MediaQuery.paddingOf(context).top;
    return ListView(
      padding: EdgeInsets.fromLTRB(0, safeTop + 48, 0, 120),
      children: [
        // The splash brand mark: a monochrome silhouette tinted with the pack
        // accent (BlendMode.srcIn) so it stays visible on every theme.
        Center(
          child: SizedBox(
            width: 50 * 399 / 346,
            height: 50,
            child: Image.asset(
              SplashScreen.logoAsset,
              fit: BoxFit.contain,
              color: cs.primary,
              colorBlendMode: BlendMode.srcIn,
            ),
          ),
        ),
        const SizedBox(height: 14),
        const Center(child: CiphernestLogo(fontSize: 34, showPlus: true)),
        const SizedBox(height: 40),
        _tile(
          cs,
          'gear',
          'Settings',
          () => Navigator.pushNamed(context, AppRoutes.settings,
              arguments: kSettingsGallerySection),
        ),
        _tile(
          cs,
          'trash',
          'Recycle Bin',
          // Straight to the Photos & Videos tab of the bin.
          () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const RecycleBinScreen(initialTab: 1))),
        ),
        _tile(
          cs,
          'cloudArrowUp',
          'Backup and sync',
          () => Navigator.pushNamed(context, AppRoutes.settings,
              arguments: kSettingsBackupSection),
        ),
      ],
    );
  }

  Widget _tile(
      ColorScheme cs, String icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: ThemeIcon(icon, color: cs.onSurface.withAlpha(120)),
      title: Text(label, style: TextStyle(color: cs.onSurface)),
      trailing:
          ThemeIcon('caretRight', size: 16, color: cs.onSurface.withAlpha(120)),
      onTap: onTap,
    );
  }
}
