import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/routes.dart';
import '../../config/theme.dart';
import '../../../services/key_manager_service.dart';
import '../../../services/cloud/account_registry.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  /// The brand mark, cropped to its glyph (399 x 346). `main()` pre-decodes
  /// it so the first frame already paints it; keep the two in sync.
  static const logoAsset = 'assets/images/ciphernest_mark.png';

  // Fixed box: the layout is final on the first frame instead of
  // re-centering when the bitmap arrives.
  static const _markHeight = 100.0;
  static const _markWidth = _markHeight * 399 / 346;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  /// Minimum time on screen. The reveal runs 1.6s; the extra beat lets the
  /// finished wordmark register before the route swap.
  static const _hold = Duration(milliseconds: 1900);

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  // Timeline (fractions of the controller):
  //   0.00-0.40  mark fades in
  //   0.22-1.00  wordmark, letter by letter, each rising from below
  //   0.78-1.00  tagline rises in as a block
  late final Animation<double> _markFade = CurvedAnimation(
    parent: _anim,
    curve: const Interval(0.0, 0.40, curve: Curves.easeOut),
  );
  late final Animation<double> _taglineFade = CurvedAnimation(
    parent: _anim,
    curve: const Interval(0.78, 1.0, curve: Curves.easeOut),
  );
  late final Animation<Offset> _taglineRise =
      Tween(begin: const Offset(0, 0.8), end: Offset.zero).animate(
    CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.78, 1.0, curve: Curves.easeOutCubic),
    ),
  );

  @override
  void initState() {
    super.initState();
    _anim.forward();
    _route();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  Future<void> _route() async {
    // The route signals load DURING the hold, not after it, so the hold is
    // the only cost the user pays.
    final results = await Future.wait<Object?>([
      Future.delayed(_hold),
      _resolveTarget(),
    ]);
    if (!mounted) return;
    // Cross-fade, not the platform slide: the wordmark has just finished
    // settling and a slide reads as a jolt.
    Navigator.pushReplacement(
      context,
      AppRoutes.fadeRoute(results[1]! as String),
    );
  }

  Future<String> _resolveTarget() async {
    // Restore the cloud account registry from secure storage.
    await AccountRegistry().load();

    // A kill between the password screen and the phrase test leaves a vault
    // that holds nothing. Resuming it would demand a password the user may
    // not remember a day later, for no benefit: wipe it and start over.
    // The window closes at markRecoveryShown(), so a kill on cloud
    // selection still resumes there after unlock.
    if (await KeyManagerService().hasSignupInProgress()) {
      await KeyManagerService().wipeVault();
      return AppRoutes.onboarding;
    }

    // Read the three signals that gate the initial route.
    final hasKey = await KeyManagerService().hasAccount();
    final prefs = await SharedPreferences.getInstance();
    // "Setup completed" means the user has reached Home at least once
    // (written by HomeScreen on mount). This is the distinction between
    // "signed out, wants to restore" and "closed mid-signup, should start
    // over from onboarding" — quitting at the master-password screen or
    // any pre-home step must NOT trigger the restore flow.
    final setupCompleted = prefs.getBool('setup_completed_v1') ?? false;

    // Decision tree:
    //   hasKey                        -> login    (login will further route
    //                                               to reconnect if there's
    //                                               no active cloud after
    //                                               unlock)
    //   !hasKey && setupCompleted     -> restore  (signed out but has done
    //                                               a full setup before)
    //   !hasKey && !setupCompleted    -> onboarding (never finished setup
    //                                               yet — start over)
    if (hasKey) return AppRoutes.login;
    if (setupCompleted) return AppRoutes.restore;
    return AppRoutes.onboarding;
  }

  @override
  Widget build(BuildContext context) {
    // The scroll view is a no-op wherever the 383dp column fits (every
    // portrait phone); it only engages in landscape, where the column
    // would otherwise overflow by ~95dp.
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Spacing reproduces the original composition, which drew the
            // uncropped 765x1024 logo bitmap at 220 wide: 92 of transparent
            // canvas above the glyph, 104 below it, then the 16 gap. The
            // cropped mark asset has none of that padding, so it is
            // restored explicitly here.
            const SizedBox(height: 92),
            // The mark is a monochrome silhouette, so it takes the active
            // pack's accent as a runtime tint — one asset, every theme.
            // Read from the ambient Theme, which main() guarantees is
            // already the saved pack on the first frame.
            FadeTransition(
              opacity: _markFade,
              child: SizedBox(
                width: SplashScreen._markWidth,
                height: SplashScreen._markHeight,
                child: Image.asset(
                  SplashScreen.logoAsset,
                  fit: BoxFit.contain,
                  color: Theme.of(context).colorScheme.primary,
                  colorBlendMode: BlendMode.srcIn,
                ),
              ),
            ),
            const SizedBox(height: 120),
              // The wordmark is a brand lockup, not reading text, so it must not
              // follow the OS font slider: at 1.3x these ten fixed 36px letters
              // grow to 46.8px and the Row overflows a 360dp screen. Reported on
              // a 720p Vivo and reproduced here. scaleDown then guarantees it
              // fits any width. The tagline below is real text and still scales.
              MediaQuery.withNoTextScaling(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: _StaggeredWordmark(
                      controller: _anim,
                      fontSize: 36,
                      start: 0.22,
                      stagger: 0.055,
                      letterSpan: 0.28,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            SlideTransition(
              position: _taglineRise,
              child: FadeTransition(
                opacity: _taglineFade,
                child: Text(
                  'Your cloud. Actually private.',
                  style: AppTypography.body(fontSize: 12),
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// The CipherNest wordmark revealed one letter at a time: each glyph fades
/// in while rising from below, offset by [stagger] from the previous one.
/// Mirrors [CiphernestLogo] styling (Bungee Hairline, "Nest" in the pack
/// accent) but lays the glyphs out individually so each can animate; the
/// Row is full width from the first frame, so nothing shifts as they land.
class _StaggeredWordmark extends StatelessWidget {
  final AnimationController controller;
  final double fontSize;
  final double start;
  final double stagger;
  final double letterSpan;

  const _StaggeredWordmark({
    required this.controller,
    required this.fontSize,
    required this.start,
    required this.stagger,
    required this.letterSpan,
  });

  static const _word = 'CipherNest';
  static const _accentFrom = 6; // "Nest"

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _word.length; i++)
          _Letter(
            controller: controller,
            begin: start + i * stagger,
            end: (start + i * stagger + letterSpan).clamp(0.0, 1.0),
            child: Text(
              _word[i],
              style: AppTypography.brand(
                fontSize: fontSize,
                color: i >= _accentFrom ? cs.primary : cs.onSurface,
              ),
            ),
          ),
      ],
    );
  }
}

class _Letter extends StatelessWidget {
  final AnimationController controller;
  final double begin;
  final double end;
  final Widget child;

  const _Letter({
    required this.controller,
    required this.begin,
    required this.end,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final fade = CurvedAnimation(
      parent: controller,
      curve: Interval(begin, end, curve: Curves.easeOut),
    );
    final rise = Tween(begin: const Offset(0, 0.6), end: Offset.zero).animate(
      CurvedAnimation(
        parent: controller,
        curve: Interval(begin, end, curve: Curves.easeOutCubic),
      ),
    );
    return SlideTransition(
      position: rise,
      child: FadeTransition(opacity: fade, child: child),
    );
  }
}
