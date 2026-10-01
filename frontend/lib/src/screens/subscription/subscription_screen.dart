import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:purchases_flutter/purchases_flutter.dart';

import '../../../services/billing_service.dart';
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
/// Prices come from the live RevenueCat offering, so they are editable from
/// the dashboard without an app update. **Opening this screen is the only
/// routine moment the app contacts RevenueCat** (see [BillingService]); it is
/// never contacted at app start.
///
/// When the offering cannot be read - no network, or the Play products do not
/// exist yet - the screen shows indicative prices and **disables the buy
/// button**, because there is no package to purchase. It never silently grants
/// an entitlement.
///
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

  Offering? _offering;
  bool _loadingPrices = true;
  bool _busy = false;

  /// Set when RevenueCat reports an active entitlement on open. The screen
  /// then confirms ownership instead of advertising a purchase.
  bool _alreadyPlus = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  /// Trigger 1 of the contact rule: one round trip that does BOTH jobs.
  ///
  /// Entitlement first. The billing ID is derived from the vault seed, so
  /// RevenueCat already knows whether this phrase owns Plus, and asking costs
  /// nothing on a call we are making anyway. Without this the screen offered
  /// to sell a subscription the user already had, Play answered "you already
  /// own this", and the only way through was to find Restore purchases by
  /// hand. Nobody should have to do that.
  ///
  /// Failure is not an error state: the screen still works, it just cannot
  /// sell anything.
  Future<void> _open() async {
    await BillingService().refreshEntitlement();
    if (!mounted) return;
    if (SubscriptionService().isPlus) {
      setState(() {
        _alreadyPlus = true;
        _loadingPrices = false;
      });
      return;
    }
    final offerings = await BillingService().offerings();
    if (!mounted) return;
    setState(() {
      _offering = offerings?.current;
      _loadingPrices = false;
    });
  }

  /// The package for the selected plan, or null when the offering is missing
  /// or does not carry that duration.
  Package? get _selectedPackage => switch (_plan) {
        _Plan.monthly => _offering?.monthly,
        _Plan.annual => _offering?.annual,
        _Plan.lifetime => _offering?.lifetime,
      };

  bool get _canBuy => !_busy && !_alreadyPlus && _selectedPackage != null;

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
    final pkg = _selectedPackage;
    if (pkg == null || _busy) return;
    setState(() => _busy = true);
    try {
      final ok = await BillingService().purchase(pkg);
      if (!mounted) return;
      if (ok) {
        Notify.info('Plus is active. Thank you.');
        _leave();
        return;
      }
      Notify.error('The purchase went through but Plus is not active yet. '
          'Try Restore purchase in a moment.');
    } on PlatformException catch (e) {
      if (!mounted) return;
      // A user backing out of the Play sheet is not a failure and must not be
      // reported as one.
      if (PurchasesErrorHelper.getErrorCode(e) ==
          PurchasesErrorCode.purchaseCancelledError) {
        return;
      }
      Notify.error(e.message ?? 'Could not complete the purchase.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Restores a subscription already attached to this vault's billing ID.
  /// Because that ID derives from the recovery phrase, this is what carries a
  /// subscription onto a new device after a phrase restore.
  Future<void> _restorePurchase() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ok = await BillingService().restore();
      if (!mounted) return;
      if (ok) {
        Notify.info('Plus restored.');
        _leave();
        return;
      }
      Notify.info('No active purchase found for this recovery phrase.');
    } on PlatformException catch (e) {
      if (!mounted) return;
      Notify.error(e.message ?? 'Could not restore purchases.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The price, and ONLY ever the store's own price string.
  ///
  /// There is deliberately no hardcoded fallback. Play carries regional
  /// overrides in twelve countries (Pakistan PKR 299/month, India INR 129, and
  /// so on), so any compiled-in figure is wrong for those users: showing
  /// "$1.99" to someone who will be charged PKR 299 is a misquote, not a
  /// rough guide. When the offering cannot be read we say so and the buy
  /// button stays disabled, which is honest and unsellable rather than cheap
  /// and wrong.
  String get _priceLine {
    if (_alreadyPlus) return 'You have Plus';
    final store = _selectedPackage?.storeProduct;
    if (store != null) {
      final p = store.priceString;
      return switch (_plan) {
        _Plan.monthly => '$p / month',
        _Plan.annual => '$p / year',
        _Plan.lifetime => '$p one-time',
      };
    }
    if (_loadingPrices) return 'Loading prices...';
    return 'See prices when you upgrade';
  }

  /// Annual saving computed from the LIVE prices of the two packages, for the
  /// same reason: the regional overrides are set per country, so a compiled-in
  /// percentage would drift the moment any one of them changes. Omitted
  /// entirely when either price is unavailable, rather than guessed.
  String? get _annualSaving {
    final m = _offering?.monthly?.storeProduct.price;
    final a = _offering?.annual?.storeProduct.price;
    if (m == null || a == null || m <= 0) return null;
    final pct = (1 - (a / (m * 12))) * 100;
    if (pct < 1) return null;
    return 'Save ${pct.round()}% vs monthly.';
  }

  String get _priceSub => _alreadyPlus
      ? 'Unlimited uploads are unlocked on this recovery phrase.'
      : switch (_plan) {
        _Plan.monthly => 'Cancel anytime.',
        _Plan.annual =>
          _annualSaving ?? 'Billed once a year instead of monthly.',
        _Plan.lifetime =>
          "Founder's Edition. Limited to the first 1,000 supporters.",
      };

  String get _ctaLabel {
    if (_alreadyPlus) return 'Plus is active';
    if (_busy) return 'Working...';
    if (_loadingPrices) return 'Loading...';
    if (_selectedPackage == null) return 'Unavailable right now';
    return _plan == _Plan.lifetime ? 'Buy Lifetime' : 'Start Plus';
  }

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
                      const SizedBox(height: 18),
                      // The price IS the card: display-class size.
                      Text(
                        _priceLine,
                        textAlign: TextAlign.center,
                        style: text.headlineLarge?.copyWith(
                          fontSize: 38,
                          fontWeight: FontWeight.w800,
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
                      const SizedBox(height: 14),
                      // The cap is the pitch: keep it inside the card,
                      // impossible to miss.
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(t.rInput),
                        ),
                        child: Text(
                          'Free stops at 1,000 uploads. Plus has no limit.',
                          textAlign: TextAlign.center,
                          style: text.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      // Plus removes the stored-file cap. That is the whole
                      // product difference, and this list must not claim
                      // otherwise: auto-sync, the editor, the recycle bin,
                      // multiple accounts, password-protected shares and
                      // custom expiry are ALL free, and not one of them has an
                      // isPlus gate anywhere in the codebase. Advertising them
                      // as paid would be selling what is already given away.
                      const _FeatureRow('Unlimited uploads, no 1,000 cap'),
                      const _FeatureRow(
                          'Everything else in CipherNest is free, and stays '
                          'free'),
                      const _FeatureRow(
                          'Your files stay in your own cloud, encrypted '
                          'before they leave the phone'),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _canBuy ? _purchase : null,
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
                    onPressed: _busy ? null : _restorePurchase,
                    child: Text(
                      'Restore purchase',
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
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
