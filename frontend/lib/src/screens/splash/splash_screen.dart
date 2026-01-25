import 'dart:async';
import 'package:flutter/material.dart';

import '../../config/routes.dart';
import '../../config/theme.dart';
import '../../../services/key_manager_service.dart'; // <--- NEW IMPORT

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
    // 1. Branding delay (Keep the logo visible for a moment)
    await Future.delayed(const Duration(milliseconds: 1500));

    // 2. Check if the Master Key exists in storage
    final hasAccount = await KeyManagerService().hasAccount();

    if (mounted) {
      if (hasAccount) {
        // User exists -> Go to Login (Biometrics/Password)
        Navigator.pushReplacementNamed(context, AppRoutes.login);
      } else {
        // New User -> Go to Onboarding
        Navigator.pushReplacementNamed(context, AppRoutes.onboarding);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Keep your existing asset
            Image.asset('assets/images/temporary_logo.png', width: 300),
            const SizedBox(height: 20),
            Text(
              'CipherNest',
              style: Theme.of(context).textTheme.headlineLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Private cloud, on your terms',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(letterSpacing: 0.2),
            ),
          ],
        ),
      ),
    );
  }
}