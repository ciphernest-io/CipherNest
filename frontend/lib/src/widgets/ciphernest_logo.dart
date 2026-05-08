import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../config/theme_controller.dart';

/// Renders "Ciphernest" in Bungee Hairline with the period (.) in the
/// current active accent color. Use [fontSize] to control scale.
class CiphernestLogo extends StatelessWidget {
  final double fontSize;
  final Color? textColor;

  const CiphernestLogo({super.key, this.fontSize = 28, this.textColor});

  @override
  Widget build(BuildContext context) {
    final accent = ThemeController().accentColors.primary;
    final color = textColor ?? Theme.of(context).colorScheme.onSurface;

    return RichText(
      text: TextSpan(
        style: AppTypography.brand(fontSize: fontSize, color: color),
        children: [
          const TextSpan(text: 'Ciphernest'),
          TextSpan(
            text: '.',
            style: AppTypography.brand(fontSize: fontSize, color: accent),
          ),
        ],
      ),
    );
  }
}