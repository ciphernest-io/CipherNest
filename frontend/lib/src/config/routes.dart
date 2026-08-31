import 'package:flutter/material.dart';

import '../screens/splash/splash_screen.dart';
import '../screens/onboarding/onboarding_screen.dart';
import '../screens/subscription/subscription_screen.dart';
import '../screens/auth/master_password_screen.dart';
import '../screens/auth/recovery_phrase_screen.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/quick_settings_screen.dart';
import '../screens/auth/reconnect_screen.dart';
import '../screens/auth/restore_phrase_screen.dart';
import '../screens/cloud_selection/cloud_selection_screen.dart';
import '../screens/home/home_screen.dart';
import '../screens/gallery/gallery_screen.dart';
import '../screens/documents/documents_screen.dart';
import '../screens/documents/other_files_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/settings/key_management_screen.dart';
import '../screens/settings/recycle_bin_screen.dart';
import '../screens/folders/folder_browser_screen.dart';
import '../screens/migration/migration_screen.dart';
import '../screens/gallery/album_detail_screen.dart';
import '../screens/music/music_home_screen.dart';
import '../screens/settings/active_shares_screen.dart';
import '../screens/share/shared_viewer_screen.dart';
import '../models/album_model.dart';

class AppRoutes {
  static const String splash = '/';
  static const String onboarding = '/onboarding';
  static const String subscription = '/subscription';
  static const String masterPassword = '/master-password';
  static const String recoveryPhrase = '/recovery-phrase';
  static const String login = '/login';
  static const String restore = '/restore';
  static const String reconnect = '/reconnect';
  static const String quickSettings = '/quick-settings';
  static const String cloudSelection = '/cloud-selection';
  static const String home = '/home';
  static const String gallery = '/gallery';
  static const String documents = '/documents';
  static const String otherFiles = '/other-files';
  static const String settings = '/settings'; 
  static const String keyManagement = '/key-management';
  static const String migration = '/migration';
  static const String albumDetail = '/album-detail';
  static const String audio = '/audio';
  static const String activeShares = '/active-shares';
  static const String sharedViewer = '/shared-viewer';
  static const String recycleBin = '/recycle-bin';
  static const String folders = '/folders';

  /// The same screen [generateRoute] would build for [name], but entering
  /// with a cross-fade instead of the platform slide. Used for the splash
  /// hand-off, where a slide reads as a jolt after the brand reveal.
  static Route<dynamic> fadeRoute(String name, {Object? arguments}) {
    final settings = RouteSettings(name: name, arguments: arguments);
    final source = generateRoute(settings) as MaterialPageRoute<dynamic>;
    return PageRouteBuilder<dynamic>(
      settings: settings,
      transitionDuration: const Duration(milliseconds: 450),
      pageBuilder: (context, _, _) => source.builder(context),
      transitionsBuilder: (_, animation, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeInOut),
        child: child,
      ),
    );
  }

  // CHANGED argument name to 'routeSettings' to avoid conflict
  static Route<dynamic> generateRoute(RouteSettings routeSettings) {
    switch (routeSettings.name) {
      case splash:
        return MaterialPageRoute(builder: (_) => const SplashScreen());

      case onboarding:
        return MaterialPageRoute(builder: (_) => const OnboardingScreen());

      case subscription:
        final rawArgs = routeSettings.arguments;
        final subArgs = rawArgs is SubscriptionScreenArgs
            ? rawArgs
            : const SubscriptionScreenArgs();
        return MaterialPageRoute(
          builder: (_) => SubscriptionScreen(args: subArgs),
        );

      case masterPassword:
        final rawArgs = routeSettings.arguments;
        final args = rawArgs is MasterPasswordArgs
            ? rawArgs
            : MasterPasswordArgs.createNew;
        return MaterialPageRoute(
          builder: (_) => MasterPasswordScreen(args: args),
        );

      case recoveryPhrase:
        final mnemonic = routeSettings.arguments as String;
        return MaterialPageRoute(
          builder: (_) => RecoveryPhraseScreen(mnemonic: mnemonic),
        );

      case login:
        return MaterialPageRoute(builder: (_) => const LoginScreen());

      case restore:
        return MaterialPageRoute(builder: (_) => const RestorePhraseScreen());

      case reconnect:
        return MaterialPageRoute(builder: (_) => const ReconnectScreen());

      case quickSettings:
        return MaterialPageRoute(builder: (_) => const QuickSettingsScreen());

      case cloudSelection:
        final rawArgs = routeSettings.arguments;
        final args = switch (rawArgs) {
          CloudSelectionArgs a => a,
          true => CloudSelectionArgs.addAnother,
          _ => CloudSelectionArgs.signup,
        };
        return MaterialPageRoute(
          builder: (_) => CloudSelectionScreen(args: args),
        );

      case home:
        return MaterialPageRoute(builder: (_) => const HomeScreen());

      case gallery:
        return MaterialPageRoute(builder: (_) => const GalleryScreen());

      case documents:
        return MaterialPageRoute(builder: (_) => const DocumentsScreen());

      case otherFiles:
        return MaterialPageRoute(builder: (_) => const OtherFilesScreen());

      case settings: // Now this correctly refers to the static String
        return MaterialPageRoute(builder: (_) => const SettingsScreen());

      case keyManagement:
        return MaterialPageRoute(builder: (_) => const KeyManagementScreen());

      case migration:
        return MaterialPageRoute(builder: (_) => const MigrationScreen());

      case albumDetail:
        final album = routeSettings.arguments as CnestAlbum;
        return MaterialPageRoute(
          builder: (_) => AlbumDetailScreen(album: album),
        );

      case audio:
        return MaterialPageRoute(builder: (_) => const MusicHomeScreen());

      case activeShares:
        return MaterialPageRoute(builder: (_) => const ActiveSharesScreen());

      case sharedViewer:
        final uri = routeSettings.arguments as Uri;
        return MaterialPageRoute(
          builder: (_) => SharedViewerScreen(shareUri: uri),
        );

      case recycleBin:
        return MaterialPageRoute(builder: (_) => const RecycleBinScreen());

      case folders:
        return MaterialPageRoute(
            builder: (_) => const FolderBrowserScreen());

      default:
        return MaterialPageRoute(
          builder: (_) =>
              const Scaffold(body: Center(child: Text('Route not found'))),
        );
    }
  }
}