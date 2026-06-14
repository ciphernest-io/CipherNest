import 'dart:io'; // <--- Added for exit(0)
import 'package:flutter/material.dart';
import '../../widgets/theme_icon.dart';

import '../../config/routes.dart';

class SubscriptionScreen extends StatelessWidget {
  const SubscriptionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 40),

              Text(
                'Unlock private cloud storage',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 12),
              Text(
                'One simple plan. No trackers. No data mining.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),

              const SizedBox(height: 40),

              _PlanCard(),

              const Spacer(),

              // "Maybe later" button -> EXITS APP
              TextButton(
                onPressed: () {
                  // Since the app requires an account/subscription to function,
                  // "Maybe later" essentially means "Close App"
                  if (Platform.isAndroid || Platform.isIOS) {
                    exit(0);
                  }
                },
                child: Text(
                  'Maybe later',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withAlpha(120)),
                ),
              ),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: cs.primary.withAlpha(102),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: cs.primary.withAlpha(38),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              'CIPHERNEST PRO',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.1,
                  ),
            ),
          ),

          const SizedBox(height: 20),

          Text(
            '\$0.99 / month',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'First month free',
            style: Theme.of(context).textTheme.bodyMedium,
          ),

          const SizedBox(height: 24),

          const _FeatureItem(text: 'Local AES-256 encryption'),
          const _FeatureItem(text: 'Google Drive & Photos support'),
          const _FeatureItem(text: 'Use on all your devices'),
          const _FeatureItem(text: 'Cancel anytime'),

          const SizedBox(height: 28),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                // MOCK PAYMENT: Assume success and go to Signup (Create Password)
                Navigator.pushReplacementNamed(
                  context,
                  AppRoutes.signup,
                );
              },
              child: const Text('Start Free Trial'),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureItem extends StatelessWidget {
  final String text;

  const _FeatureItem({required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Icon(
            themeIconData('checkCircle', selected: true),
            color: cs.primary,
            size: 18,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
        ],
      ),
    );
  }
}