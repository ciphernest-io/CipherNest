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

  static Route<dynamic> generateRoute(RouteSettings settings) {
    switch (settings.name) {
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
        return MaterialPageRoute(builder: (_) => const CloudSelectionScreen());

      case home:
        return MaterialPageRoute(builder: (_) => const HomeScreen());

      case gallery:
        return MaterialPageRoute(builder: (_) => const GalleryScreen());

      case documents:
        return MaterialPageRoute(builder: (_) => const DocumentsScreen());

      default:
        return MaterialPageRoute(
          builder: (_) =>
              const Scaffold(body: Center(child: Text('Route not found'))),
        );
    }
  }
}
