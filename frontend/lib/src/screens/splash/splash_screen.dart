import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/routes.dart';
import '../../config/theme.dart';
import '../../widgets/ciphernest_logo.dart';
import '../../../services/key_manager_service.dart';
import '../../../services/cloud/account_registry.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkUser(); // <--- Changed from Timer to _checkUser
  }

  Future<void> _checkUser() async {
    // 1. Branding delay. Kept short so we're not dead-time before the first
    // useful screen. 700ms is enough for the wordmark to register.
    await Future.delayed(const Duration(milliseconds: 700));

    // 2. Restore the cloud account registry from secure storage.
    await AccountRegistry().load();

    // 3. Read the three signals that gate the initial route.
    final hasKey = await KeyManagerService().hasAccount();
    final prefs = await SharedPreferences.getInstance();
    // "Setup completed" means the user has reached Home at least once
    // (written by HomeScreen on mount). This is the distinction between
    // "signed out, wants to restore" and "closed mid-signup, should start
    // over from onboarding" — quitting at the master-password screen or
    // any pre-home step must NOT trigger the restore flow.
    final setupCompleted =
        prefs.getBool('setup_completed_v1') ?? false;

    if (!mounted) return;

    // Decision tree:
    //   hasKey                        -> login    (login will further route
    //                                               to reconnect if there's
    //                                               no active cloud after
    //                                               unlock)
    //   !hasKey && setupCompleted     -> restore  (signed out but has done
    //                                               a full setup before)
    //   !hasKey && !setupCompleted    -> onboarding (never finished setup
    //                                               yet — start over)
    String target;
    if (hasKey) {
      target = AppRoutes.login;
    } else if (setupCompleted) {
      target = AppRoutes.restore;
    } else {
      target = AppRoutes.onboarding;
    }
    Navigator.pushReplacementNamed(context, target);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              Theme.of(context).brightness == Brightness.dark
                  ? 'assets/images/ciphernest_logo_white.png'
                  : 'assets/images/ciphernest_logo_black.png',
              width: 220,
            ),
            const SizedBox(height: 16),
            const CiphernestLogo(fontSize: 36),
            const SizedBox(height: 8),
            Text(
              'Your cloud. Actually private.',
              style: AppTypography.body(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}