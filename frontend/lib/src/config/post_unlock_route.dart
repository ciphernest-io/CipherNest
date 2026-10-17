import 'package:shared_preferences/shared_preferences.dart';

import '../../services/app_lock_service.dart';
import '../../services/cloud/account_registry.dart';
import '../screens/cloud_selection/cloud_selection_screen.dart'
    show CloudSelectionArgs;
import '../screens/subscription/subscription_screen.dart'
    show SubscriptionScreenArgs;
import 'billing.dart';
import 'flags.dart';
import 'routes.dart';

/// Where a freshly unlocked vault lands. One rule for both doors in: the
/// login screen after a password or fingerprint, and the splash when the
/// vault has no password and opens itself.
///
/// Resume-by-progress. Home if an active cloud account is registered (or
/// the onboarding quick-settings step if that was never finished).
/// Reconnect is for a vault that HAD a cloud and lost the session; if no
/// account was EVER registered this is a signup interrupted at the cloud
/// picker, and reconnect is a dead end there. A kill on the signup paywall
/// comes back to the paywall.
class PostUnlockRoute {
  const PostUnlockRoute(this.name, [this.arguments]);

  final String name;
  final Object? arguments;

  static Future<PostUnlockRoute> resolve() async {
    // Vault is unlocked: start the inactivity countdown (a no-op for a
    // passwordless vault, which has nothing to lock behind).
    AppLockService().recordActivity();
    final prefs = await SharedPreferences.getInstance();

    if (AccountRegistry().activeAccount != null) {
      final settled = prefs.getBool('quick_settings_shown_v1') ?? false;
      return PostUnlockRoute(
          settled ? AppRoutes.home : AppRoutes.quickSettings);
    }
    if (kPaywallEnabled &&
        !AccountRegistry().hasAnyAccount &&
        prefs.getString(kPaywallPendingPrefKey) == 'signup') {
      return const PostUnlockRoute(
        AppRoutes.subscription,
        SubscriptionScreenArgs(nextRoute: AppRoutes.cloudSelection),
      );
    }
    // Both remaining cases are the provider picker. "Reconnect" was a
    // separate interstitial that only renamed the same choice.
    return PostUnlockRoute(
      AppRoutes.cloudSelection,
      AccountRegistry().hasAnyAccount
          ? CloudSelectionArgs.reconnect
          : CloudSelectionArgs.signup,
    );
  }
}
