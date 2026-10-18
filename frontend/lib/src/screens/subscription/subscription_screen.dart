import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../services/billing_service.dart';
import '../../../services/notify.dart';
import '../../../services/subscription_service.dart';
import '../../config/billing.dart';
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

/// Single-screen paywall. One filled Plus card, a copy of the one on the
/// website's pricing section: the term switch with its sliding thumb, the
/// price with its digit roll, the two-line feature list and a rectangular
/// call to action. "Continue on Free" below the card is the only exit; there
/// is no close control.
///
/// Prices come from the live RevenueCat offering, so they are editable from
/// the dashboard without an app update and are shown in the store's own
/// currency. When the offering cannot be read the card says so and the buy
/// button stays disabled. It never silently grants an entitlement.
///
/// Someone whose phrase already owns Plus never sees this as a flow step:
/// the entitlement check on open advances straight to [SubscriptionScreenArgs.nextRoute].
class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key, this.args = const SubscriptionScreenArgs()});

  final SubscriptionScreenArgs args;

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

enum _Term { monthly, yearly, lifetime }

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  _Term _term = _Term.yearly;

  Offering? _offering;
  bool _loadingPrices = true;
  bool _busy = false;

  /// True until [_open] has heard whether this phrase already owns Plus. A
  /// flow step for an owner leaves immediately, and drawing the card in the
  /// meantime flashed it for a frame on the restore-phrase route.
  bool _checking = true;

  /// Set when RevenueCat reports an active entitlement on an UPSELL open. In a
  /// flow the screen leaves instead. Here the card turns into the plan
  /// changer: a monthly subscriber is offered Yearly and Lifetime, a yearly
  /// one Lifetime, and a lifetime owner just sees that Plus is active.
  bool _alreadyPlus = false;
  PlusPlan _plan = PlusPlan.none;

  /// The plans a subscriber can move UP to. Never shorter than the current
  /// one: Play would prorate a downgrade and the product has no reason to
  /// offer one.
  List<_Term> get _upgradeTerms => switch (_plan) {
        PlusPlan.monthly => const [_Term.yearly, _Term.lifetime],
        PlusPlan.yearly => const [_Term.lifetime],
        _ => const [],
      };

  bool get _changingPlan => _alreadyPlus && _upgradeTerms.isNotEmpty;

  /// What the switch offers: every term on a fresh sale, only the longer
  /// ones for a subscriber.
  List<_Term> get _terms => _alreadyPlus ? _upgradeTerms : _Term.values;

  static String _termLabel(_Term t) => switch (t) {
        _Term.monthly => 'Monthly',
        _Term.yearly => 'Yearly',
        _Term.lifetime => 'Lifetime',
      };

  @override
  void initState() {
    super.initState();
    _open();
  }

  /// One round trip that does both jobs: entitlement first, then prices.
  ///
  /// The billing ID derives from the vault seed, so RevenueCat already knows
  /// whether this phrase owns Plus. If it does there is nothing to sell: a
  /// flow step moves on at once, an upsell confirms ownership. Without this
  /// the screen offered to sell a subscription the user already had and the
  /// only way through was a greyed-out button and "Continue on Free".
  Future<void> _open() async {
    await BillingService().refreshEntitlement();
    if (!mounted) return;
    if (SubscriptionService().isPlus) {
      if (widget.args.nextRoute != null) {
        _leave();
        return;
      }
      final plan = SubscriptionService().plan;
      setState(() {
        _alreadyPlus = true;
        _plan = plan;
        _checking = false;
      });
      if (_upgradeTerms.isEmpty) {
        setState(() => _loadingPrices = false);
        return;
      }
      // Fall through: the longer plans need live prices like a fresh sale.
      setState(() => _term = _upgradeTerms.first);
    }
    setState(() => _checking = false);
    final offerings = await BillingService().offerings();
    if (!mounted) return;
    setState(() {
      _offering = offerings?.current;
      _loadingPrices = false;
    });
  }

  Package? get _selectedPackage => switch (_term) {
        _Term.monthly => _offering?.monthly,
        _Term.yearly => _offering?.annual,
        _Term.lifetime => _offering?.lifetime,
      };

  bool get _canBuy =>
      !_busy && (!_alreadyPlus || _changingPlan) && _selectedPackage != null;

  /// Plain words for the common Play refusals. The SDK's own descriptions
  /// are written for developers ("The device or user is not allowed to make
  /// the purchase") and read as an accusation on a declined card.
  static String _purchaseErrorText(PlatformException e) {
    final code = PurchasesErrorHelper.getErrorCode(e);
    switch (code) {
      case PurchasesErrorCode.purchaseNotAllowedError:
        return 'Payment declined. Nothing charged';
      case PurchasesErrorCode.paymentPendingError:
        return 'Payment pending in Google Play';
      case PurchasesErrorCode.productAlreadyPurchasedError:
        return 'Owned by another phrase. Use Restore purchase';
      case PurchasesErrorCode.networkError:
      case PurchasesErrorCode.offlineConnectionError:
        return 'No connection to Google Play';
      case PurchasesErrorCode.storeProblemError:
        return 'Google Play error. Try again';
      default:
        return 'Purchase failed (${code.name})';
    }
  }

  /// After Lifetime is bought on top of a subscription. Play keeps renewing
  /// the subscription until the user cancels it, and only Play can cancel
  /// it, so say so and open the page.
  Future<void> _promptCancelSubscription() async {
    final plan = _plan == PlusPlan.yearly ? 'yearly' : 'monthly';
    final open = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Lifetime is yours'),
        content: Text(
            'Your $plan subscription still renews until you cancel it in '
            'Google Play. Cancel it now so you are not charged again.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Later')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Open Google Play')),
        ],
      ),
    );
    if (open != true) return;
    final url = await BillingService().managementUrl() ??
        'https://play.google.com/store/account/subscriptions'
            '?sku=plus&package=io.ciphernest.vault';
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// Every exit converges here: flow steps advance to [SubscriptionScreenArgs.nextRoute]
  /// (stack cleared, the phrase screens must not survive beneath), upsell
  /// pushes pop, and a bare stack falls back to home.
  ///
  /// Leaving by any door clears the pending marker, so a later launch does
  /// not route back here.
  void _leave() {
    unawaited(SharedPreferences.getInstance()
        .then((p) => p.remove(kPaywallPendingPrefKey)));
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
      // Monthly to Yearly is a change WITHIN the Play subscription, deferred
      // so the paid month runs out first and the yearly charge lands on the
      // existing renewal date. Lifetime is a separate one-time product, so
      // it is bought outright and the subscription is cancelled by the user
      // in Play (prompted below); Play has no "replace a subscription with a
      // one-time purchase".
      // Play identifies the subscription being replaced by its subscription
      // id alone ("plus"); the SDK may report the entitlement's product as
      // "plus:monthly" (subscription:basePlan), which Play does not know.
      final oldProduct =
          SubscriptionService().currentProductId?.split(':').first;
      final deferredSwitch = _changingPlan &&
          _term == _Term.yearly &&
          oldProduct != null &&
          oldProduct.isNotEmpty;
      final ok = await BillingService().purchase(
        pkg,
        change: deferredSwitch
            ? StoreProductChangeInfo(oldProduct,
                replacementMode: StoreReplacementMode.deferred)
            : null,
      );
      if (!mounted) return;
      if (ok) {
        if (deferredSwitch) {
          Notify.info('Yearly starts when this month ends');
        } else if (_changingPlan) {
          await _promptCancelSubscription();
          if (!mounted) return;
        } else {
          Notify.info('Plus is active');
        }
        _leave();
        return;
      }
      Notify.error('Purchased, but not active yet. Try Restore');
    } on PlatformException catch (e) {
      if (!mounted) return;
      // A user backing out of the Play sheet is not a failure and must not be
      // reported as one.
      if (PurchasesErrorHelper.getErrorCode(e) ==
          PurchasesErrorCode.purchaseCancelledError) {
        return;
      }
      Notify.error(_purchaseErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Restores a subscription already attached to this vault's billing ID.
  /// Because that ID derives from the recovery phrase, this is what carries a
  /// subscription onto a new device after a phrase restore.
  /// Restore is a MOVE, not a copy. Plus is a Google Play purchase, so it
  /// belongs to the Google account, and RevenueCat (restore behaviour:
  /// Transfer) attaches it to one App User ID, that is one recovery phrase,
  /// at a time. Restoring inside a different vault pulls it away from the
  /// vault that had it. Play also sells one Plus per account, so on a new
  /// phrase this is the ONLY way to get Plus: the buy button is refused as
  /// already owned. Hence a confirmation that says exactly what happens,
  /// rather than hiding the button.
  Future<void> _restorePurchase() async {
    if (_busy) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore Plus to this phrase?'),
        content: const Text(
            'Plus belongs to your Google account and to one recovery phrase '
            'at a time. Restoring brings it to this phrase. If another vault '
            'was using it, that vault goes back to the free limit. Its files '
            'are untouched.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Restore')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final ok = await BillingService().restore();
      if (!mounted) return;
      if (ok) {
        Notify.info('Plus restored');
        _leave();
        return;
      }
      Notify.info('No purchase found for this phrase');
    } on PlatformException catch (e) {
      if (!mounted) return;
      Notify.error('Restore failed (${PurchasesErrorHelper.getErrorCode(e).name})');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The store's own price string, and nothing else. There is deliberately no
  /// hardcoded fallback: Play carries regional overrides in twelve countries,
  /// so any compiled-in figure misquotes those users.
  String? get _priceString => _selectedPackage?.storeProduct.priceString;

  String get _periodLabel {
    if (_alreadyPlus && !_changingPlan) return 'You have Plus';
    if (_priceString == null) {
      return _loadingPrices ? 'Loading prices...' : 'Unavailable right now';
    }
    return switch (_term) {
      _Term.monthly => 'per month',
      _Term.yearly => 'per year',
      _Term.lifetime => 'once',
    };
  }

  /// Yearly saving computed from the LIVE prices, for the same reason the
  /// price is: the regional overrides are set per country, so a compiled-in
  /// percentage drifts the moment any one of them changes.
  String? get _yearlySaving {
    final m = _offering?.monthly?.storeProduct.price;
    final a = _offering?.annual?.storeProduct.price;
    if (m == null || a == null || m <= 0) return null;
    final pct = (1 - (a / (m * 12))) * 100;
    if (pct < 1) return null;
    return 'Save ${pct.round()}% vs monthly.';
  }

  String get _note => _changingPlan
      ? switch (_term) {
          _Term.lifetime =>
            'One payment. Then cancel your subscription in Google Play so '
                'it stops renewing.',
          _ => 'Starts when your current month ends. Nothing is charged '
              'until then.',
        }
      : _alreadyPlus
      ? 'Unlimited uploads are unlocked on this recovery phrase.'
      : switch (_term) {
          _Term.monthly => 'Cancel anytime.',
          _Term.yearly => _yearlySaving ?? 'Billed once a year.',
          _Term.lifetime => 'One-time. Plus for life. Limited seats.',
        };

  String get _ctaLabel {
    if (_alreadyPlus && !_changingPlan) return 'Plus is active';
    if (_busy) return 'Working...';
    if (_loadingPrices) return 'Loading...';
    if (_selectedPackage == null) return 'Unavailable right now';
    if (_changingPlan) {
      return _term == _Term.lifetime ? 'Buy Lifetime' : 'Switch to Yearly';
    }
    return _term == _Term.lifetime ? 'Buy Lifetime' : 'Start Plus';
  }

  String get _headline => _changingPlan
      ? 'Change your plan'
      : _alreadyPlus
          ? 'You have Plus'
          : 'Unlock unlimited uploads';

  String get _subhead => _changingPlan
      ? 'Longer plans cost less over time. Nothing else changes.'
      : _alreadyPlus
          ? 'Unlimited uploads on this recovery phrase.'
          : 'Free up to 1,000 files. Plus only lifts the upload cap.';

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      // Same bare canvas as the route fade lands on; the check is one round
      // trip and an owner never sees the card at all.
      return const PopScope(
        canPop: false,
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final t = ThemeController().tokens;

    // The card is filled with the page's foreground, so everything inside it
    // flips: its text is the page background and its mutes are mixed between
    // the two. Same construction as the website's `.card-plus`.
    final cardBg = cs.onSurface;
    final cardFg = cs.surface;
    final muted = Color.lerp(cardFg, cardBg, 0.38)!;

    // System back mirrors Continue on Free. Without this, canPop is false
    // on the flow stack and the OS back-press is silently swallowed.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _continueFree();
      },
      child: Scaffold(
        body: SafeArea(
          // Fixed composition, not a fill: the card is as tall as its
          // content and nothing more. The scroll view is only for landscape
          // and very large font sizes, where the column cannot fit.
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _headline,
                  textAlign: TextAlign.center,
                  style: text.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _subhead,
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.64),
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(t.rCardLg),
                    border: Border.all(color: cardBg, width: 2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _changingPlan ? 'Change plan' : 'Plus',
                        style: text.titleLarge?.copyWith(
                          color: cardFg,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 24),
                      _PriceLine(
                        price: _alreadyPlus ? null : _priceString,
                        period: _periodLabel,
                        ink: cardFg,
                        muted: muted,
                      ),
                      const SizedBox(height: 8),
                      // Two lines reserved so the card does not jump between
                      // terms, as on the website.
                      ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Text(
                          _note,
                          style: text.bodySmall?.copyWith(
                            color: muted,
                            height: 1.45,
                          ),
                        ),
                      ),
                      if (_terms.length > 1) ...[
                        const SizedBox(height: 18),
                        _TermSwitch(
                          labels: _terms.map(_termLabel).toList(),
                          index: _terms.indexOf(_term),
                          onChanged: (i) =>
                              setState(() => _term = _terms[i]),
                          track: cardFg.withValues(alpha: 0.12),
                          thumb: cardFg,
                          onThumb: cardBg,
                          offText: muted,
                        ),
                      ],
                      const SizedBox(height: 32),
                      _Feature('Everything in Free', ink: cardFg, tick: muted),
                      const SizedBox(height: 14),
                      _Feature('Unlimited file uploads',
                          ink: cardFg, tick: muted),
                      const SizedBox(height: 36),
                      SizedBox(
                        height: 52,
                        width: double.infinity,
                        // Rectangular, in the card's own ink with the card's
                        // colour for the label: the website's swapped CTA.
                        // No ripple and no overlay; it is a plain fill.
                        child: FilledButton(
                          onPressed: _alreadyPlus && !_changingPlan
                              ? _leave
                              : (_canBuy ? _purchase : null),
                          style: FilledButton.styleFrom(
                            backgroundColor: cardFg,
                            foregroundColor: cardBg,
                            disabledBackgroundColor:
                                cardFg.withValues(alpha: 0.35),
                            disabledForegroundColor:
                                cardBg.withValues(alpha: 0.6),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(t.rInput),
                            ),
                          ).copyWith(
                            overlayColor:
                                const WidgetStatePropertyAll(Colors.transparent),
                            splashFactory: NoSplash.splashFactory,
                          ),
                          child: Text(
                            _ctaLabel,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
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
                      _alreadyPlus ? 'Back' : 'Continue on Free',
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

/// Price and period on one line: the store string with rolling digits, then
/// the period in the muted ink. Mirrors the website's `.price` row.
class _PriceLine extends StatelessWidget {
  const _PriceLine({
    required this.price,
    required this.period,
    required this.ink,
    required this.muted,
  });

  final String? price;
  final String period;
  final Color ink;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    final digitStyle = TextStyle(
      fontSize: 40,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.6,
      height: 1.0,
      color: ink,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    // Currency symbols and codes sit smaller and muted, like `.sym`.
    final symStyle = TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w500,
      height: 1.0,
      color: muted,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(
          child: _RollingPrice(
            text: price ?? '',
            digitStyle: digitStyle,
            symStyle: symStyle,
          ),
        ),
        if (price != null) const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Text(
            period,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

/// A price string whose digits roll into place: each digit is a column of
/// 0 to 9 slid vertically to the wanted one, staggered 45ms per digit, and
/// the whole thing animates its width when the string gains or loses a
/// character. Non-digits (currency symbol, code, separators) are static text,
/// so any store format works: "$1.99", "PKR 299.00", "Rs 2,999".
class _RollingPrice extends StatelessWidget {
  const _RollingPrice({
    required this.text,
    required this.digitStyle,
    required this.symStyle,
  });

  final String text;
  final TextStyle digitStyle;
  final TextStyle symStyle;

  @override
  Widget build(BuildContext context) {
    final tp = TextPainter(
      text: TextSpan(text: '0', style: digitStyle),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final dw = tp.width;
    final dh = tp.height;

    final children = <Widget>[];
    var digitIndex = 0;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      final code = ch.codeUnitAt(0);
      if (code >= 0x30 && code <= 0x39) {
        children.add(_DigitReel(
          key: ValueKey('d$i'),
          digit: code - 0x30,
          width: dw,
          height: dh,
          style: digitStyle,
          delay: Duration(milliseconds: 45 * digitIndex),
        ));
        digitIndex++;
      } else if (ch == '.' || ch == ',') {
        children.add(Text(ch, key: ValueKey('p$i'), style: digitStyle));
      } else if (ch == ' ') {
        children.add(SizedBox(key: ValueKey('w$i'), width: dw * 0.35));
      } else {
        children.add(Padding(
          key: ValueKey('s$i'),
          padding: const EdgeInsets.only(right: 2, bottom: 2),
          child: Text(ch, style: symStyle),
        ));
      }
    }

    return AnimatedSize(
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: children,
      ),
    );
  }
}

class _DigitReel extends StatelessWidget {
  const _DigitReel({
    super.key,
    required this.digit,
    required this.width,
    required this.height,
    required this.style,
    required this.delay,
  });

  final int digit;
  final double width;
  final double height;
  final TextStyle style;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    // The website's reel: 520ms on cubic-bezier(0.2, 0.7, 0.2, 1), each
    // later digit starting 45ms after the one before it. The delay is folded
    // into the curve as a leading flat interval.
    final total = const Duration(milliseconds: 520) + delay;
    final lead = delay.inMilliseconds / total.inMilliseconds;
    return SizedBox(
      width: width,
      height: height,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: digit.toDouble()),
        duration: total,
        curve: Interval(lead, 1, curve: const Cubic(0.2, 0.7, 0.2, 1)),
        builder: (_, v, child) => Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(top: -v * height, left: 0, child: child!),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var d = 0; d < 10; d++)
              SizedBox(
                width: width,
                height: height,
                child: Center(child: Text('$d', style: style)),
              ),
          ],
        ),
      ),
    );
  }
}

/// The term switch: a pill track with a thumb that slides under the selected
/// label. Three equal tabs; the selected label is painted in the card colour
/// because the thumb is painted in the card's ink.
class _TermSwitch extends StatelessWidget {
  const _TermSwitch({
    required this.labels,
    required this.index,
    required this.onChanged,
    required this.track,
    required this.thumb,
    required this.onThumb,
    required this.offText,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  final Color track;
  final Color thumb;
  final Color onThumb;
  final Color offText;

  @override
  Widget build(BuildContext context) {
    const pad = 3.0;
    final labelStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ) ??
        const TextStyle(fontWeight: FontWeight.w600);
    return SizedBox(
      height: 38,
      child: LayoutBuilder(
        builder: (context, c) {
          final tabW = (c.maxWidth - pad * 2) / labels.length;
          return DecoratedBox(
            decoration: BoxDecoration(
              color: track,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                  left: pad + index * tabW,
                  top: pad,
                  bottom: pad,
                  width: tabW,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: thumb,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (var i = 0; i < labels.length; i++)
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onChanged(i),
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 200),
                              style: labelStyle.copyWith(
                                color: i == index ? onThumb : offText,
                              ),
                              child: Text(
                                labels[i],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature(this.label, {required this.ink, required this.tick});

  final String label;
  final Color ink;
  final Color tick;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ThemeIcon('checkCircle', size: 15, color: tick),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: ink),
          ),
        ),
      ],
    );
  }
}
