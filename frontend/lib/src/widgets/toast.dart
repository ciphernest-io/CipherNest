import 'package:flutter/material.dart';

import '../../services/notify.dart';
import '../config/theme_controller.dart';
import 'theme_icon.dart';

/// The transient-message pill rendered by the global overlay. Small,
/// auto-dismissing, swipeable on its own bounds — everything beside it
/// passes touches through (unlike the full-width SnackBars it replaced).
class ToastPill extends StatelessWidget {
  const ToastPill({super.key});

  @override
  Widget build(BuildContext context) {
    final toasts = ToastController();
    return AnimatedBuilder(
      animation: toasts,
      builder: (context, _) {
        final event = toasts.current;
        final cs = Theme.of(context).colorScheme;
        final t = ThemeController().tokens;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: event == null
              ? const SizedBox.shrink()
              : Dismissible(
                  key: ValueKey('toast-${event.seq}'),
                  direction: DismissDirection.horizontal,
                  onDismissed: (_) => toasts.dismiss(),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 320),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(t.rPill),
                      border: Border.all(
                          color: event.isError
                              ? t.danger.withAlpha(160)
                              : cs.outline.withAlpha(90)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ThemeIcon(
                          event.isError ? 'warningCircle' : 'info',
                          size: 18,
                          color: event.isError
                              ? t.danger
                              : cs.onSurface.withAlpha(160),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            event.message,
                            style: TextStyle(
                              color: cs.onSurface,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        );
      },
    );
  }
}
