import 'package:flutter/material.dart';
import '../../services/subscription_service.dart';
import '../config/theme.dart';

/// The CipherNest wordmark. Always Bungee Hairline (the one font that never
/// changes across theme packs) — only the "Nest" half is tinted with the
/// current pack's accent.
class CiphernestLogo extends StatelessWidget {
  final double fontSize;
  final Color? textColor;

  /// Appends " Plus" while the entitlement is active. The wordmark is where
  /// someone looks to confirm what they are paying for, so it is the honest
  /// place to show it.
  final bool showPlus;

  const CiphernestLogo({
    super.key,
    this.fontSize = 28,
    this.textColor,
    this.showPlus = false,
  });

  @override
  Widget build(BuildContext context) {
    // Ambient theme, not the controller singleton — the theme is what has
    // actually painted around us (the controller may still be loading prefs).
    final accent = Theme.of(context).colorScheme.primary;
    final color = textColor ?? Theme.of(context).colorScheme.onSurface;

    final plus = showPlus && SubscriptionService().isPlus;

    return RichText(
      // A wordmark is a brand lockup, not reading text, so it must not follow
      // the OS font slider. At larger sizes it otherwise outgrows its row and
      // overflows, which is what happened on the splash screen.
      textScaler: TextScaler.noScaling,
      text: TextSpan(
        style: AppTypography.brand(fontSize: fontSize, color: color),
        children: [
          const TextSpan(text: 'Cipher'),
          TextSpan(
            text: 'Nest',
            style: AppTypography.brand(fontSize: fontSize, color: accent),
          ),
          if (plus)
            TextSpan(
              text: ' Plus',
              style: AppTypography.brand(fontSize: fontSize, color: color),
            ),
        ],
      ),
    );
  }
}
