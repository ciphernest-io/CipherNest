import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../config/routes.dart';
import '../../config/theme_controller.dart';

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
      illustration: 'assets/images/illustrations/page_1.svg',
      title: 'Your cloud is not private.',
      description:
          "Big tech can scan and index everything you store with them. Their promise not to misuse holds until it doesn't: a breach, a subpoena, a change of terms.",
    ),
    _OnboardingPageData(
      illustration: 'assets/images/illustrations/page_2.svg',
      title: 'Only you hold the key.',
      description:
          'Photos, videos, documents. Sealed with AES-256 on your device before anything leaves it. Your cloud only ever stores unreadable ciphertext.',
    ),
    _OnboardingPageData(
      illustration: 'assets/images/illustrations/page_3.svg',
      title: 'Keep your cloud.',
      description:
          'CipherNest layers over your existing cloud. Nothing to migrate, no second storage bill. Set up in two minutes.',
    ),
    _OnboardingPageData(
      illustration: 'assets/images/illustrations/page_4.svg',
      title: "Don't trust us.\nRead the code.",
      description:
          'CipherNest is open source under GPLv3. The entire encryption pipeline is on GitHub, auditable by anyone.',
      anchorTitle: false,
    ),
  ];

  bool get _isFirstPage => _currentIndex == 0;
  bool get _isLastPage => _currentIndex == _pages.length - 1;

  void _next() {
    if (_isLastPage) {
      _finish();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _finish() {
    // NOTE: we intentionally do NOT persist a "user swiped through the
    // slides" flag here. Splash-gating on that would misroute users who
    // close the app mid-signup (e.g. at the master-password screen) into
    // the restore flow instead of onboarding. The setup-complete flag is
    // written only once the user actually reaches HomeScreen.
    Navigator.pushNamedAndRemoveUntil(
      context,
      AppRoutes.masterPassword,
      (route) => false,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Landscape-class heights (never a portrait phone): tighter control
    // block so the pager keeps enough height for art + copy side by side.
    final compact = MediaQuery.sizeOf(context).height < 500;
    final secondaryStyle = TextStyle(
      color: Theme.of(context).colorScheme.onSurface.withAlpha(120),
    );

    // Secondary action per page: the restore entry on page 1 only (it is a
    // first-decision, not a per-slide nag), Skip on the middle pages, and
    // nothing on the last page where Get Started is the only way forward.
    // The slot keeps a fixed height so the layout never jumps.
    Widget? secondary;
    if (_isFirstPage) {
      secondary = TextButton(
        onPressed: () => Navigator.pushNamed(context, AppRoutes.restore),
        child: Text(
          'I already have a recovery phrase',
          style: secondaryStyle.copyWith(
            decoration: TextDecoration.underline,
          ),
        ),
      );
    } else if (!_isLastPage) {
      secondary = TextButton(
        onPressed: _finish,
        child: Text('Skip', style: secondaryStyle),
      );
    }

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
                itemBuilder: (_, index) =>
                    _OnboardingPage(data: _pages[index], compact: compact),
              ),
            ),

            // 2. The Control Area (Fixed height)
            Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, compact ? 8 : 24),
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
                  SizedBox(height: compact ? 12 : 32),

                  // Main Button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _next,
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.symmetric(
                          vertical: compact ? 10 : 16,
                        ),
                      ),
                      child: Text(
                        _isLastPage ? 'Get Started' : 'Next',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),

                  SizedBox(height: compact ? 4 : 16),

                  // minHeight, not a fixed height: the page-1 label wraps
                  // to two lines on narrow phones with a large font scale.
                  ConstrainedBox(
                    constraints: BoxConstraints(minHeight: compact ? 36 : 48),
                    child: Center(child: secondary),
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

  /// Landscape-class heights: art beside the copy instead of above it.
  final bool compact;

  const _OnboardingPage({required this.data, required this.compact});

  /// Laid-out height of [text] in [style] at [width], honoring the OS font
  /// scale so the measurement matches what the Text widget paints.
  static double _measureHeight(
    String text,
    TextStyle? style,
    double width,
    TextScaler scaler,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout(maxWidth: width);
    final height = painter.height;
    painter.dispose();
    return height;
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final titleStyle = textTheme.headlineMedium?.copyWith(fontSize: 24);
    final bodyStyle = textTheme.bodyMedium;
    final art = SvgPicture.asset(
      data.illustration,
      fit: BoxFit.contain,
      alignment: Alignment.center,
      colorMapper: _IllustrationPalette.of(context),
    );
    final title = Text(
      data.title,
      textAlign: TextAlign.center,
      style: titleStyle,
    );
    final description = Text(
      data.description,
      textAlign: TextAlign.center,
      style: bodyStyle,
    );

    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
        child: Row(
          children: [
            Expanded(flex: 2, child: art),
            const SizedBox(width: 24),
            Expanded(
              flex: 3,
              child: Center(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      title,
                      const SizedBox(height: 10),
                      description,
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        final scaler = MediaQuery.textScalerOf(context);
        final copyWidth = constraints.maxWidth - 64;
        final block =
            _measureHeight(data.title, titleStyle, copyWidth, scaler) +
                14 +
                _measureHeight(data.description, bodyStyle, copyWidth, scaler);

        // Illustration: a fixed band (30% of the page, 60% of the width)
        // pushed down from the top by 9% plus a fixed 125 (tuned on the
        // A55, where the page is ~640dp tall). The 0.29 cap returns the
        // same value there (the curves cross at h = 625) and stops the
        // constant from eating the whole page on shorter phones.
        var topInset = min(h * 0.09 + 125, h * 0.29);
        var artHeight = h * 0.30;
        double copyAvail() => h - topInset - 16 - artHeight;
        // Shorter pages give the copy room by returning inset first, then
        // art height, each down to a floor. Neither branch fires at 411.
        if (block > copyAvail()) {
          topInset = max(h * 0.04, topInset - (block - copyAvail()));
        }
        if (block > copyAvail()) {
          artHeight = max(h * 0.18, artHeight - (block - copyAvail()));
        }

        double lead;
        if (data.anchorTitle) {
          // Title top is ANCHORED, identical across pages: the spot a 3:2
          // split (with a trailing 41) gives a reference block of one title
          // line + three body lines. Centering the actual block instead let
          // a longer description push its title up (page 1 sat visibly
          // higher than pages 2 and 3).
          final ref = _measureHeight('X', titleStyle, copyWidth, scaler) +
              14 +
              _measureHeight('X\nX\nX', bodyStyle, copyWidth, scaler);
          lead = 0.6 * (copyAvail() - 41 - ref);
        } else {
          // Centered block: 3:2 split with a trailing 41 (page 4, whose
          // two-line title is meant to sit as a centered block).
          lead = 0.6 * (copyAvail() - 41 - block);
        }
        // Never push the copy off the page. If it still cannot fit after
        // the floors above, the scroll view is the last resort.
        lead = lead.clamp(0.0, max(0.0, copyAvail() - block));

        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(32, topInset, 32, 16),
          child: Column(
            children: [
              SizedBox(
                height: artHeight,
                child: FractionallySizedBox(widthFactor: 0.6, child: art),
              ),
              SizedBox(height: lead),
              title,
              const SizedBox(height: 14),
              description,
            ],
          ),
        );
      },
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
        color: isActive ? cs.primary : cs.primary.withAlpha(77),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

/// Re-inks the unDraw illustrations for the active theme. Their palette is
/// drawn for a white page: the near-black ink (clothes, frames, outlines)
/// vanishes on a dark background, so in dark mode it becomes the pack's
/// faint text tone, a dark gray that still reads as "dark" against the
/// page. Hair is tagged in the SVG files with a sentinel one step off the
/// ink (#0A0A15, indistinguishable in light mode) so it can take a
/// separate, darker shade and not merge with the clothes. Light mode
/// keeps the artwork as authored. Skin, paper, and mid-grays pass through
/// untouched in both.
class _IllustrationPalette extends ColorMapper {
  final Color ink;
  final Color hair;

  const _IllustrationPalette({required this.ink, required this.hair});

  static const _inkSources = {0xFF090814, 0xFF2F2E41, 0xFF3F3D56, 0xFF464353};
  static const _hairSource = 0xFF0A0A15;

  static ColorMapper? of(BuildContext context) {
    if (Theme.of(context).brightness != Brightness.dark) return null;
    final t = ThemeController().tokens;
    return _IllustrationPalette(
      ink: t.fgFaint,
      hair: Color.lerp(t.fgFaint, t.bg, 0.45)!,
    );
  }

  @override
  Color substitute(
    String? id,
    String elementName,
    String attributeName,
    Color color,
  ) {
    final argb = color.toARGB32();
    if (argb == _hairSource) return hair;
    if (_inkSources.contains(argb)) return ink;
    return color;
  }
}

class _OnboardingPageData {
  final String illustration;
  final String title;
  final String description;

  /// Anchor the title top at the shared line (pages 1-3). False keeps the
  /// copy block centered by the 3:2 split instead (page 4, whose two-line
  /// title is meant to sit as a centered block).
  final bool anchorTitle;

  const _OnboardingPageData({
    required this.illustration,
    required this.title,
    required this.description,
    this.anchorTitle = true,
  });
}
