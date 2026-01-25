import 'package:flutter/material.dart';
import '../../config/routes.dart';
import '../../config/theme.dart';

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
      title: 'Your cloud. Your keys.',
      description: 'CipherNest encrypts your photos and documents before they ever leave your device — so only you can read them.',
    ),
    _OnboardingPageData(
      title: 'Privacy shouldn’t be a trade-off.',
      description: 'Big tech scans and indexes your files. CipherNest keeps your memories private.',
    ),
    _OnboardingPageData(
      title: 'Security you don’t have to think about.',
      description: 'Files are encrypted locally using AES-256 GCM. Your data stays unreadable to cloud providers — by design.',
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
    Navigator.pushNamedAndRemoveUntil(
      context, 
      AppRoutes.subscription, 
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
                          child: const Text(
                            'I already have an account',
                            style: TextStyle(color: Colors.grey, decoration: TextDecoration.underline),
                          ),
                        )
                      : (_currentIndex != _pages.length - 1
                        ? TextButton(
                            onPressed: _finish,
                            child: const Text('Skip', style: TextStyle(color: Colors.grey)),
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
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(horizontal: 4),
      width: isActive ? 20 : 8, // Make active dot wider
      height: 8,
      decoration: BoxDecoration(
        color: isActive
            ? AppColors.primary
            : AppColors.primary.withOpacity(0.3),
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