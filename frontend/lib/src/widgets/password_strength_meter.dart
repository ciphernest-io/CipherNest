import 'package:flutter/material.dart';

import '../config/theme.dart' show AppColors;

/// A four-segment bar with a text label. Purely presentational — the
/// consumer computes the [score] (0..4) and the [label] (see
/// [PasswordStrengthLabel]) from whatever rules they care about.
///
/// Segments fill left-to-right in a colour that ramps from `AppColors.error`
/// through `AppColors.warning` into `cs.primary`, ending in
/// `AppColors.success` at full score. Empty segments render as a muted
/// track so the total bar length is stable at every score.
///
/// The meter is deliberately decoupled from the confirm-password check.
/// Password strength is a property of the password alone; confirmation is
/// a separate CTA gate.
class PasswordStrengthMeter extends StatelessWidget {
  const PasswordStrengthMeter({
    super.key,
    required this.score,
    this.label,
  }) : assert(score >= 0 && score <= 4);

  final int score;
  final String? label;

  static const int segmentCount = 4;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final trackColor = cs.onSurface.withValues(alpha: 0.12);
    final filled = _fillColor(cs);
    final labelColor = _labelColor(cs);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: List.generate(segmentCount, (i) {
            final isFilled = i < score;
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                  right: i == segmentCount - 1 ? 0 : 4,
                ),
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: isFilled ? filled : trackColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            );
          }),
        ),
        if (label != null) ...[
          const SizedBox(height: 6),
          Text(
            label!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: labelColor,
                  fontWeight: FontWeight.w500,
                ),
          ),
        ],
      ],
    );
  }

  Color _fillColor(ColorScheme cs) {
    if (score <= 1) return AppColors.error;
    if (score == 2) return AppColors.warning;
    if (score == 3) return cs.primary;
    return AppColors.success;
  }

  Color _labelColor(ColorScheme cs) {
    if (score <= 1) return AppColors.error;
    if (score == 2) return AppColors.warning;
    if (score == 4) return AppColors.success;
    return cs.onSurface.withValues(alpha: 0.75);
  }
}

/// Canonical labels for a 0..4 score. `PasswordStrengthLabel.forScore(3)`.
class PasswordStrengthLabel {
  static const List<String> _labels = [
    'Very weak',
    'Weak',
    'Good',
    'Strong',
    'Excellent',
  ];

  static String forScore(int score) {
    if (score < 0) return _labels.first;
    if (score >= _labels.length) return _labels.last;
    return _labels[score];
  }
}
