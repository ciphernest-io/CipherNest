import 'package:flutter/material.dart';

import '../../../services/notify.dart';
import '../../../services/subscription_service.dart';
import '../../config/routes.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';

/// Route arguments. A non-null [nextRoute] means the paywall is a STEP in a
/// flow (the post-phrase slot): every exit, paid or free, advances there
/// with the stack cleared. Absent = pushed as a contextual upsell; exits
/// pop back.
class SubscriptionScreenArgs {
  const SubscriptionScreenArgs({this.nextRoute, this.nextArguments});

  final String? nextRoute;
  final Object? nextArguments;
}

/// Single-screen paywall (Aug 31 revamp): one plan card with a
/// Monthly / Annual / Lifetime switcher, and "Continue on Free" as the only
/// mention of the free tier. Position: right after the phrase step, in
/// every flow that has one (signup type-back, restore phrase entry).
///
/// Billing is stubbed until the payments project lands: the CTA grants the
/// LOCAL entitlement (SubscriptionService seam) so Free/Plus gates are
/// testable end to end; RevenueCat replaces only the CTA body.
/// `kPaywallEnabled` in flags.dart gates whether flows route here at all.
class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key, this.args = const SubscriptionScreenArgs()});

  final SubscriptionScreenArgs args;

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

enum _Plan { monthly, annual, lifetime }

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  _Plan _plan = _Plan.annual;

  /// Every exit converges here: flow steps advance to [SubscriptionScreenArgs.nextRoute]
  /// (stack cleared — the phrase screens must not survive beneath), upsell
  /// pushes pop, and a bare stack falls back to home.
  void _leave() {
    final next = widget.args.nextRoute;
    if (next != null) {
      Navigator.pushNamedAndRemoveUntil(
        context,
        next,
        (route) => false,
        arguments: widget.args.nextArguments,
      );
      return;
    }
    if (Navigator.canPop(context)) {
      Navigator.pop(context);
      return;
    }
    Navigator.pushReplacementNamed(context, AppRoutes.home);
  }

  void _continueFree() => _leave();

  Future<void> _purchase() async {
    // Billing stub: grants the LOCAL entitlement so the Free/Plus gates
    // (including the 1,000-file cap) are testable end to end. RevenueCat's
    // purchase flow replaces this body; the screen and call site stay.
    await SubscriptionService().setPlusEntitlement(true);
    Notify.info('Plus unlocked on this device. Billing arrives with v1.1.');
    if (!mounted) return;
    _leave();
  }

  void _restorePurchase() {
    Notify.info('Purchase restore lands with billing in v1.1.');
  }

  String get _priceLine => switch (_plan) {
        _Plan.monthly => r'$1.99 / month',
        _Plan.annual => r'$19.99 / year',
        _Plan.lifetime => r'$39 one-time',
      };

  String get _priceSub => switch (_plan) {
        _Plan.monthly => 'Cancel anytime.',
        _Plan.annual => r'About $1.66 a month. Two months free.',
        _Plan.lifetime =>
          "Founder's Edition. Limited to the first 1,000 supporters.",
      };

  String get _ctaLabel =>
      _plan == _Plan.lifetime ? 'Buy Lifetime' : 'Start Plus';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final t = ThemeController().tokens;

    // System back mirrors Continue on Free. Without this, canPop is false
    // on the flow stack and the OS back-press is silently swallowed.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _continueFree();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: ThemeIcon('x', color: cs.onSurface),
            onPressed: _continueFree,
            tooltip: 'Continue on Free',
          ),
        ),
        body: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Unlock unlimited uploads',
                  textAlign: TextAlign.center,
                  style: text.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Free stores your first 1,000 files with the same '
                  'encryption. Plus removes the cap and turns everything on.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.72),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: cs.surface,
                    borderRadius: BorderRadius.circular(t.rCardLg),
                    border: Border.all(
                      color: cs.primary.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Three segments ~ 250dp; scale down on 320dp-class
                      // cards. No-op at 411.
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: SegmentedButton<_Plan>(
                          segments: const [
                            ButtonSegment(
                                value: _Plan.monthly,
                                label: Text('Monthly')),
                            ButtonSegment(
                                value: _Plan.annual, label: Text('Annual')),
                            ButtonSegment(
                                value: _Plan.lifetime,
                                label: Text('Lifetime')),
                          ],
                          selected: {_plan},
                          onSelectionChanged: (s) =>
                              setState(() => _plan = s.first),
                          showSelectedIcon: false,
                          style: ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _priceLine,
                        textAlign: TextAlign.center,
                        style: text.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _priceSub,
                        textAlign: TextAlign.center,
                        style: text.bodySmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const _FeatureRow('Unlimited encrypted uploads'),
                      const _FeatureRow(
                          'Auto-sync every album in the background'),
                      const _FeatureRow('In-app photo editor'),
                      const _FeatureRow(
                          'Password-protected shares, custom expiry'),
                      const _FeatureRow('30-day recycle bin'),
                      const _FeatureRow('Multiple cloud accounts'),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _purchase,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: Text(
                          _ctaLabel,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: TextButton(
                    onPressed: _continueFree,
                    child: Text(
                      'Continue on Free',
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.72),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                Center(
                  child: TextButton(
                    onPressed: _restorePurchase,
                    child: Text(
                      'Restore purchase',
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Prices in USD. Billed through Google Play. Cancel anytime '
                  'in your Play Store subscriptions.',
                  textAlign: TextAlign.center,
                  style: text.bodySmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.45),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ThemeIcon(
            'checkCircle',
            size: 18,
            selected: true,
            color: ThemeController().tokens.success,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.85),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
