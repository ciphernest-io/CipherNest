import 'package:flutter/material.dart';

import '../../config/flags.dart';
import '../../config/routes.dart';
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _controller = PageController();
  int _currentIndex = 0;

  final List<_OnboardingPageData> _pages = const [
    _OnboardingPageData(
      title: "Your data isn't as private as you think.",
      description:
          "Every major cloud can scan, index, and analyze whatever you upload. Whether they do or don't is their promise, not math. CipherNest makes the promise obsolete; what leaves your phone is unreadable to anyone but you.",
    ),
    _OnboardingPageData(
      title: 'CipherNest encrypts everything on your device.',
      description:
          'AES-256. Photos, videos, documents, whatever. Sealed on your phone before it touches the internet. Your cloud stores unreadable ciphertext. Only you can decrypt it.',
    ),
    _OnboardingPageData(
      title: 'No new cloud. No new bill.',
      description:
          'CipherNest layers on the Google Drive or OneDrive you already have. Your existing storage becomes an encrypted vault. Two minutes to set up.',
    ),
    _OnboardingPageData(
      title: "Don't trust us. Read the code.",
      description:
          'CipherNest is open source under GPL v3. Every line of the encryption pipeline is on GitHub. Auditable, yours to verify. Heck, fork it if you want. This is what real privacy looks like.',
    ),
  ];

  void _next() {
    if (_currentIndex < _pages.length - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      _finish();
    }
  }

  void _finish() {
    // NOTE: we intentionally do NOT persist a "user swiped through the
    // slides" flag here. Splash-gating on that would misroute users who
    // close the app mid-signup (e.g. at the master-password screen) into
    // the restore flow instead of onboarding. The setup-complete flag is
    // written only once the user actually reaches HomeScreen.
    //
    // With the paywall flag on (dev/test build), show the tier sheet
    // before signup. In the release AAB the flag is off and we jump
    // straight to master-password creation.
    final target = kPaywallEnabled
        ? AppRoutes.subscription
        : AppRoutes.masterPassword;
    Navigator.pushNamedAndRemoveUntil(
      context,
      target,
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // 1. The Slider (Takes available space)
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _pages.length,
                onPageChanged: (index) => setState(() => _currentIndex = index),
                itemBuilder: (_, index) => _OnboardingPage(data: _pages[index]),
              ),
            ),
            
            // 2. The Control Area (Fixed height)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                children: [
                  // Indicators
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      _pages.length,
                      (index) => _Indicator(isActive: index == _currentIndex),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Main Button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _next,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: Text(
                        _currentIndex == _pages.length - 1 ? 'Get Started' : 'Next',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Secondary Action (Skip OR Restore)
                  // We use a fixed height container to prevent layout jumping
                  SizedBox(
                    height: 48,
                    child: Center(
                      child: _currentIndex == 0
                      ? TextButton(
                          onPressed: () => Navigator.pushNamed(context, AppRoutes.restore),
                          child: Text(
                            'I already have an account',
                            style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withAlpha(120), decoration: TextDecoration.underline),
                          ),
                        )
                      : (_currentIndex != _pages.length - 1
                        ? TextButton(
                            onPressed: _finish,
                            child: Text('Skip', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withAlpha(120))),
                          )
                        : const SizedBox.shrink()), // Empty space on last slide
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnboardingPage extends StatelessWidget {
  final _OnboardingPageData data;

  const _OnboardingPage({required this.data});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            data.title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 20),
          Text(
            data.description,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}

class _Indicator extends StatelessWidget {
  final bool isActive;

  const _Indicator({required this.isActive});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(horizontal: 4),
      width: isActive ? 20 : 8, // Make active dot wider
      height: 8,
      decoration: BoxDecoration(
        color: isActive
            ? cs.primary
            : cs.primary.withAlpha(77),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

class _OnboardingPageData {
  final String title;
  final String description;

  const _OnboardingPageData({
    required this.title,
    required this.description,
  });
}