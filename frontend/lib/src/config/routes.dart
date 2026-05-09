import 'package:flutter/material.dart';

import '../screens/splash/splash_screen.dart';
import '../screens/onboarding/onboarding_screen.dart';
import '../screens/subscription/subscription_screen.dart';
import '../screens/auth/signup_screen.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/restore_account_screen.dart';
import '../screens/cloud_selection/cloud_selection_screen.dart';
import '../screens/home/home_screen.dart';
import '../screens/gallery/gallery_screen.dart';
import '../screens/documents/documents_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/settings/key_management_screen.dart';
import '../screens/migration/migration_screen.dart';
import '../screens/gallery/album_detail_screen.dart';
import '../models/album_model.dart';

class AppRoutes {
  static const String splash = '/';
  static const String onboarding = '/onboarding';
  static const String subscription = '/subscription';
  static const String signup = '/signup';
  static const String login = '/login';
  static const String restore = '/restore';
  static const String cloudSelection = '/cloud-selection';
  static const String home = '/home';
  static const String gallery = '/gallery';
  static const String documents = '/documents';
  static const String settings = '/settings'; 
  static const String keyManagement = '/key-management';
  static const String migration = '/migration';
  static const String albumDetail = '/album-detail';

  // CHANGED argument name to 'routeSettings' to avoid conflict
  static Route<dynamic> generateRoute(RouteSettings routeSettings) {
    switch (routeSettings.name) {
      case splash:
        return MaterialPageRoute(builder: (_) => const SplashScreen());

      case onboarding:
        return MaterialPageRoute(builder: (_) => const OnboardingScreen());

      case subscription:
        return MaterialPageRoute(builder: (_) => const SubscriptionScreen());

      case signup:
        return MaterialPageRoute(builder: (_) => const SignUpScreen());

      case login:
        return MaterialPageRoute(builder: (_) => const LoginScreen());

      case restore:
        return MaterialPageRoute(builder: (_) => const RestoreAccountScreen());

      case cloudSelection:
        final addAnother = (routeSettings.arguments as bool?) ?? false;
        return MaterialPageRoute(
          builder: (_) => CloudSelectionScreen(isAddAnother: addAnother),
        );

      case home:
        return MaterialPageRoute(builder: (_) => const HomeScreen());

      case gallery:
        return MaterialPageRoute(builder: (_) => const GalleryScreen());

      case documents:
        return MaterialPageRoute(builder: (_) => const DocumentsScreen());

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

      default:
        return MaterialPageRoute(
          builder: (_) =>
              const Scaffold(body: Center(child: Text('Route not found'))),
        );
    }
  }
}