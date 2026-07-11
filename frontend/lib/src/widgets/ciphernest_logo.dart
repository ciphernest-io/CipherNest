import 'package:flutter/material.dart';
import '../config/theme.dart';

/// The CipherNest wordmark. Always Bungee Hairline (the one font that never
/// changes across theme packs) — only the "Nest" half is tinted with the
/// current pack's accent.
class CiphernestLogo extends StatelessWidget {
  final double fontSize;
  final Color? textColor;

  const CiphernestLogo({super.key, this.fontSize = 28, this.textColor});

  @override
  Widget build(BuildContext context) {
    // Ambient theme, not the controller singleton — the theme is what has
    // actually painted around us (the controller may still be loading prefs).
    final accent = Theme.of(context).colorScheme.primary;
    final color = textColor ?? Theme.of(context).colorScheme.onSurface;

    return RichText(
      text: TextSpan(
        style: AppTypography.brand(fontSize: fontSize, color: color),
        children: [
          const TextSpan(text: 'Cipher'),
          TextSpan(
            text: 'Nest',
            style: AppTypography.brand(fontSize: fontSize, color: accent),
          ),
        ],
      ),
    );
  }
}
