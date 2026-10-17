import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// Set when RevenueCat reports an active entitlement on an UPSELL open. In a
  /// flow the screen leaves instead, so this only drives the pop-back copy.
  bool _alreadyPlus = false;

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

  Package? get _selectedPackage => switch (_term) {
        _Term.monthly => _offering?.monthly,
        _Term.yearly => _offering?.annual,
        _Term.lifetime => _offering?.lifetime,
      };

  bool get _canBuy => !_busy && !_alreadyPlus && _selectedPackage != null;

  /// Plain words for the common Play refusals. The SDK's own descriptions
  /// are written for developers ("The device or user is not allowed to make
  /// the purchase") and read as an accusation on a declined card.
  static String _purchaseErrorText(PlatformException e) {
    switch (PurchasesErrorHelper.getErrorCode(e)) {
      case PurchasesErrorCode.purchaseNotAllowedError:
        return 'Google Play declined the payment. Nothing was charged.';
      case PurchasesErrorCode.paymentPendingError:
        return 'Google Play is still processing the payment. Plus turns on '
            'when it completes.';
      case PurchasesErrorCode.productAlreadyPurchasedError:
        return 'This vault already owns Plus. Try Restore purchase.';
      case PurchasesErrorCode.networkError:
      case PurchasesErrorCode.offlineConnectionError:
        return 'No connection to Google Play. Check your network and try '
            'again.';
      case PurchasesErrorCode.storeProblemError:
        return 'Google Play could not complete the purchase. Try again in a '
            'moment.';
      default:
        return e.message ?? 'Could not complete the purchase.';
    }
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
      Notify.error(_purchaseErrorText(e));
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

  /// The store's own price string, and nothing else. There is deliberately no
  /// hardcoded fallback: Play carries regional overrides in twelve countries,
  /// so any compiled-in figure misquotes those users.
  String? get _priceString => _selectedPackage?.storeProduct.priceString;

  String get _periodLabel {
    if (_alreadyPlus) return 'You have Plus';
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

  String get _note => _alreadyPlus
      ? 'Unlimited uploads are unlocked on this recovery phrase.'
      : switch (_term) {
          _Term.monthly => 'Cancel anytime.',
          _Term.yearly => _yearlySaving ?? 'Billed once a year.',
          _Term.lifetime => 'One-time. Plus for life. Limited seats.',
        };

  String get _ctaLabel {
    if (_alreadyPlus) return 'Plus is active';
    if (_busy) return 'Working...';
    if (_loadingPrices) return 'Loading...';
    if (_selectedPackage == null) return 'Unavailable right now';
    return _term == _Term.lifetime ? 'Buy Lifetime' : 'Start Plus';
  }

  @override
  Widget build(BuildContext context) {
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
          // The card takes whatever height the phone has left after the
          // header and the two text links, so the CTA sits near the bottom
          // instead of the lower half of the screen sitting empty. The
          // scroll view only engages when the column genuinely does not fit
          // (landscape, very large font sizes).
          child: LayoutBuilder(builder: (context, viewport) {
            const pad = EdgeInsets.fromLTRB(20, 28, 20, 24);
            return SingleChildScrollView(
            padding: pad,
            child: ConstrainedBox(
            constraints: BoxConstraints(
                minHeight: viewport.maxHeight - pad.vertical),
            child: IntrinsicHeight(
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
                  'Free up to 1,000 files. Plus only lifts the upload cap.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.64),
                  ),
                ),
                const SizedBox(height: 24),
                Expanded(
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(t.rCardLg),
                    border: Border.all(color: cardBg, width: 2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Plus',
                        style: text.titleLarge?.copyWith(
                          color: cardFg,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 18),
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
                        constraints: const BoxConstraints(minHeight: 38),
                        child: Text(
                          _note,
                          style: text.bodySmall?.copyWith(
                            color: muted,
                            height: 1.45,
                          ),
                        ),
                      ),
                      if (!_alreadyPlus) ...[
                        const SizedBox(height: 14),
                        _TermSwitch(
                          labels: const ['Monthly', 'Yearly', 'Lifetime'],
                          index: _term.index,
                          onChanged: (i) =>
                              setState(() => _term = _Term.values[i]),
                          track: cardFg.withValues(alpha: 0.12),
                          thumb: cardFg,
                          onThumb: cardBg,
                          offText: muted,
                        ),
                      ],
                      // Features and the CTA anchor to the card's bottom.
                      const Spacer(),
                      const SizedBox(height: 20),
                      _Feature('Everything in Free', ink: cardFg, tick: muted),
                      const SizedBox(height: 10),
                      _Feature('Unlimited file uploads',
                          ink: cardFg, tick: muted),
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 48,
                        width: double.infinity,
                        // Rectangular, in the card's own ink with the card's
                        // colour for the label: the website's swapped CTA.
                        // No ripple and no overlay; it is a plain fill.
                        child: FilledButton(
                          onPressed: _alreadyPlus
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
            );
          }),
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
