import 'package:flutter/material.dart';

import '../../services/activity_center.dart';
import '../app.dart';
import '../config/theme_controller.dart';
import 'activity_sheet.dart';
import 'theme_icon.dart';
import 'toast.dart';

/// Bottom-inset claim STACK for the globally mounted overlay. Screens whose
/// bottom edge carries chrome (gallery's nav bar, music's mini player, the
/// viewer's action pill) claim their height in initState and release in
/// dispose; the overlay floats above `_claims.last` — route disposal is
/// LIFO, so the last claim always belongs to the visible screen.
class ActivityPillInset {
  ActivityPillInset._();

  static final List<InsetClaim> _claims = [];
  static final ValueNotifier<double> effective = ValueNotifier(0);

  static InsetClaim claim(double height) {
    final c = InsetClaim._(height);
    _claims.add(c);
    _recompute();
    return c;
  }

  static void _recompute() {
    effective.value = _claims.isEmpty ? 0 : _claims.last._height;
  }
}

class InsetClaim {
  double _height;
  bool _released = false;
  InsetClaim._(this._height);

  void update(double height) {
    _height = height;
    ActivityPillInset._recompute();
  }

  void release() {
    if (_released) return;
    _released = true;
    ActivityPillInset._claims.remove(this);
    ActivityPillInset._recompute();
  }
}

/// The global overlay layer mounted in the MaterialApp builder — toast pill
/// stacked above the activity pill, bottom-center, clear of per-screen
/// chrome and the keyboard. Stateless over singletons: the builder re-runs
/// on every theme change, so rebuilds must be pure paint.
class ActivityOverlay extends StatelessWidget {
  const ActivityOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: ActivityPillInset.effective,
      builder: (context, inset, _) => Positioned(
        left: 0,
        right: 0,
        bottom: 16 + inset + MediaQuery.viewInsetsOf(context).bottom,
        child: const SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ToastPill(),
              SizedBox(height: 8),
              ActivityPill(),
            ],
          ),
        ),
      ),
    );
  }
}

/// The collapsed progress pill: ring/spinner + label + "+N" chip. Tap
/// expands the task sheet; horizontal swipe hides it (work continues).
/// Occupies only its own bounds — touches beside it pass through.
class ActivityPill extends StatelessWidget {
  const ActivityPill({super.key});

  @override
  Widget build(BuildContext context) {
    final center = ActivityCenter();
    return AnimatedBuilder(
      animation: center,
      builder: (context, _) {
        final mode = center.pillMode;
        final task = center.pillTask;
        if (mode == PillMode.hidden || task == null) {
          return const SizedBox.shrink();
        }
        final cs = Theme.of(context).colorScheme;
        final t = ThemeController().tokens;
        final terminal = mode == PillMode.terminal;
        final failed = task.state == ActivityState.failure;
        final label = terminal
            ? (task.resultMessage ?? task.label)
            : task.label;
        final extra = center.extraRunningCount;

        final Widget leading = terminal
            ? ThemeIcon(failed ? 'warning' : 'check',
                color: failed ? t.danger : cs.primary, size: 22)
            : SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  value: task.fraction,
                  strokeWidth: 3,
                ),
              );

        return Dismissible(
          key: ValueKey('activity-pill-${task.id}-${mode.name}'),
          direction: DismissDirection.horizontal,
          onDismissed: (_) => center.suppressPill(),
          child: GestureDetector(
            onTap: () {
              final ctx = App.navigatorKey.currentContext;
              if (ctx != null) showActivitySheet(ctx);
            },
            child: Container(
              constraints: const BoxConstraints(maxWidth: 340),
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(t.rPill),
                border: Border.all(
                    color: failed && terminal
                        ? t.danger.withAlpha(160)
                        : cs.outline.withAlpha(90)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  leading,
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (!terminal && extra > 0) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(t.rPill),
                      ),
                      child: Text(
                        '+$extra',
                        style: TextStyle(
                          color: cs.onSurface.withAlpha(160),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
