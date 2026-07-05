import 'package:flutter/material.dart';

import '../../services/cnest_errors.dart';
import 'theme_icon.dart';

/// Canonical entry point for displaying a [CnestError] to the user.
///
/// Renders a modal bottom sheet with the error's icon, title, message and
/// (optionally) a primary action button. A "Dismiss" text button is always
/// present. Errors whose [CnestError.shouldSurface] is false no-op silently.
///
/// If [onPrimaryAction] is provided, it runs when the user taps the primary
/// button and the sheet then closes. Otherwise the primary button just
/// dismisses the sheet.
Future<void> showCnestError(
  BuildContext context,
  CnestError error, {
  VoidCallback? onPrimaryAction,
}) async {
  if (!error.shouldSurface) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _FriendlyErrorSheet(
      error: error,
      onPrimaryAction: onPrimaryAction,
    ),
  );
}

class _FriendlyErrorSheet extends StatelessWidget {
  const _FriendlyErrorSheet({
    required this.error,
    required this.onPrimaryAction,
  });

  final CnestError error;
  final VoidCallback? onPrimaryAction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final actionLabel = error.primaryActionLabel;

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(
            top: BorderSide(color: cs.outline.withValues(alpha: 0.4)),
            left: BorderSide(color: cs.outline.withValues(alpha: 0.4)),
            right: BorderSide(color: cs.outline.withValues(alpha: 0.4)),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            ThemeIcon(error.iconName, size: 40, color: cs.primary),
            const SizedBox(height: 12),
            Text(
              error.title,
              style: textTheme.titleLarge?.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              error.message,
              style: textTheme.bodyMedium?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.75),
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            if (actionLabel != null)
              ElevatedButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  onPrimaryAction?.call();
                },
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(actionLabel),
              ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                'Dismiss',
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
