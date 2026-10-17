import 'dart:async';

import 'package:flutter/material.dart';
import '../../../services/secure_window_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/billing_service.dart';
import '../../../services/key_manager_service.dart';
import '../../config/billing.dart';
import '../../config/flags.dart';
import '../../config/routes.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';
import '../../../services/sensitive_clipboard.dart';
import '../subscription/subscription_screen.dart'
    show SubscriptionScreenArgs;

/// Signup step 2 of 2. Two internal stages:
///  1. Display: numbered grid of the 12 mnemonic words + advice cards.
///  2. Type-back: three random positions must be typed correctly.
///
/// The mnemonic is passed as `Navigator` route argument. Kept in memory
/// only; never persisted here (KeyManagerService already committed the
/// derived master key).
class RecoveryPhraseScreen extends StatefulWidget {
  const RecoveryPhraseScreen({super.key, required this.mnemonic});

  final String mnemonic;

  @override
  State<RecoveryPhraseScreen> createState() => _RecoveryPhraseScreenState();
}

class _RecoveryPhraseScreenState extends State<RecoveryPhraseScreen>with SecureScreenMixin {
  late final List<String> _words = widget.mnemonic.trim().split(RegExp(r'\s+'));

  @override
  void initState() {
    super.initState();
    // Warm the RevenueCat offering while the user reads their phrase. The
    // paywall is the very next screen and used to show a visible gap waiting
    // on the live prices; by the time it opens the cache is populated.
    if (kPaywallEnabled) {
      unawaited(BillingService().offerings());
    }
  }

  Future<void> _continue() async {
    // Wipes the encrypted-mnemonic blob + clears the signup-in-progress flag.
    // Must run before we hand off to cloud selection.
    await KeyManagerService().markRecoveryShown();
    if (!mounted) return;
    if (kPaywallEnabled) {
      // Mark the step so a kill on the paywall resumes there, not past it.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kPaywallPendingPrefKey, 'signup');
      if (!mounted) return;
      Navigator.pushReplacementNamed(
        context,
        AppRoutes.subscription,
        arguments: const SubscriptionScreenArgs(
          nextRoute: AppRoutes.cloudSelection,
        ),
      );
      return;
    }
    Navigator.pushReplacementNamed(context, AppRoutes.cloudSelection);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Forward-only: the password step is committed and the phrase is being
      // shown, so there is nothing to go back to.
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          // Restoring an existing vault stays reachable from here. Pushed, not
          // replaced, so the restore screen's back arrow returns with this
          // vault intact.
          TextButton(
            onPressed: () => Navigator.pushNamed(context, AppRoutes.restore),
            child: const Text('Have a phrase?'),
          ),
        ],
      ),
      body: SafeArea(
        child: _DisplayStage(words: _words, onContinue: _continue),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stage 1 — Display
// ---------------------------------------------------------------------------

class _DisplayStage extends StatelessWidget {
  const _DisplayStage({required this.words, required this.onContinue});

  final List<String> words;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    // Content scrolls only when it must (360x640-class bodies); the CTA
    // lives OUTSIDE the scroll view so it is pinned to the bottom without
    // IntrinsicHeight, which cannot measure the grid's viewport.
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Your recovery phrase',
                  textAlign: TextAlign.center,
                  style: text.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Save these twelve words down now, in order. They are the '
                  'key to your vault. Lose them and every file in your vault '
                  'is gone for good.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.72),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),
                _WordGrid(words: words),
                const SizedBox(height: 8),
                Center(
                  child: TextButton.icon(
                    icon: ThemeIcon('copy', size: 16, color: cs.primary),
                    label: Text(
                      'Copy to clipboard',
                      style: TextStyle(color: cs.primary),
                    ),
                    onPressed: () => _confirmCopy(context, words.join(' ')),
                  ),
                ),
                const SizedBox(height: 12),
                const _AdviceRow(
                  icon: 'notebook',
                  text: 'Write it down on paper.',
                ),
                const SizedBox(height: 6),
                const _AdviceRow(
                  icon: 'key',
                  text: 'Or keep it in a password manager.',
                ),
                const SizedBox(height: 6),
                _AdviceRow(
                  icon: 'warning',
                  iconTint: ThemeController().tokens.warning,
                  text: "We wouldn't recommend emailing or texting it to yourself.",
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onContinue,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: const Text(
                "I have written it down",
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmCopy(BuildContext context, String phrase) async {
    final cs = Theme.of(context).colorScheme;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Copy to clipboard?'),
        content: const Text(
          'Other apps can read the clipboard, and some phones sync it to the cloud. Paste it into your password manager right away, then clear the clipboard.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: cs.error),
            child: const Text('Copy'),
          ),
        ],
      ),
    );
    if (proceed == true) {
      // No toast: Android 13+ shows its own "copied" overlay.
      await SensitiveClipboard.copy(phrase);
    }
  }
}

class _WordGrid extends StatelessWidget {
  const _WordGrid({required this.words});
  final List<String> words;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    // Tile HEIGHT is what must stay constant, not the aspect ratio: the
    // original 2.6 was tuned at 411dp (tile 115.67 wide -> 44.5 tall).
    // Deriving the ratio from the actual tile width keeps 44.5dp at every
    // width, so an 8-letter word still gets a full text line at 320dp
    // (2.6 there gave 32.8dp tiles and clipped the phrase). Width comes
    // from MediaQuery, not a LayoutBuilder: the page sits inside an
    // IntrinsicHeight (pinned CTA), which cannot measure a LayoutBuilder.
    const refTileWidth = (411.0 - 48 - 16) / 3;
    const refTileHeight = refTileWidth / 2.6;
    final gridWidth = MediaQuery.sizeOf(context).width - 48;
    final tileWidth = (gridWidth - 16) / 3;
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 3,
      childAspectRatio: tileWidth / refTileHeight,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: List.generate(words.length, (i) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(t.rInput),
            border: Border.all(color: cs.outline.withValues(alpha: 0.4)),
          ),
          child: Row(
            children: [
              Text(
                '${i + 1}',
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.45),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              // Never ellipsize a recovery word: below ~77dp of text width
              // the glyphs shrink instead (no-op at 411, where every
              // BIP-39 word fits at 14pt).
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    words[i],
                    style: TextStyle(
                      fontFamily: t.monoFontFamily,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

class _AdviceRow extends StatelessWidget {
  const _AdviceRow({required this.icon, required this.text, this.iconTint});

  final String icon;
  final String text;
  final Color? iconTint;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      // Top-aligned: on narrow phones the third punchline wraps to two
      // lines and a centered icon floats between them.
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ThemeIcon(
          icon,
          size: 20,
          color: iconTint ?? cs.primary,
          selected: iconTint == null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.85),
                ),
          ),
        ),
      ],
    );
  }
}
