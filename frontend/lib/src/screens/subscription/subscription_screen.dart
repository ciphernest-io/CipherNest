import 'package:flutter/material.dart';

import '../../config/routes.dart';
import '../../config/theme.dart' show AppColors;
import '../../widgets/theme_icon.dart';

/// Three-tier paywall (Free / Plus / Lifetime). In v1.0 the CTAs are mock:
/// every purchase path routes to master-password creation without touching
/// billing. Live purchases land in v1.1 when RevenueCat is wired.
///
/// Guarded upstream by `kPaywallEnabled` in `flags.dart`. When that flag is
/// off, the onboarding CTA skips this screen entirely.
class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

enum _TierKind { free, plus, lifetime }

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  bool _annual = true;

  /// Which card is expanded, if any. Only one at a time; tapping the current
  /// one collapses it. Default is null (all collapsed) so the initial paint
  /// shows 3 compact cards side-by-side, all fitting on one screen.
  _TierKind? _expanded;

  void _toggleExpanded(_TierKind kind) {
    setState(() => _expanded = _expanded == kind ? null : kind);
  }

  void _continueFree() {
    // Onboarding pushed us with pushNamedAndRemoveUntil, so there's nothing
    // behind us. Advance instead of trying to pop into oblivion. If we ever
    // get shown from Settings (v1.1), that entry point will push normally
    // and pop below will just close the sheet.
    if (Navigator.canPop(context)) {
      Navigator.pop(context);
      return;
    }
    Navigator.pushReplacementNamed(context, AppRoutes.masterPassword);
  }

  void _mockPurchase() {
    // Placeholder for RevenueCat.purchase(). In v1.0 the vault is created
    // without billing; the tier UI is here for design + walkthrough only.
    Navigator.pushReplacementNamed(context, AppRoutes.masterPassword);
  }

  void _restorePurchase() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Purchase restore lands with billing in v1.1.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    // System back (Android hardware / gesture) mirrors the X-close. Without
    // this, canPop is false from the onboarding stack and the OS back-press
    // is silently swallowed — the paywall appears "stuck."
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
        leading: IconButton(
          icon: ThemeIcon('x', color: cs.onSurface),
          onPressed: _continueFree,
          tooltip: 'Close',
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
                'Three ways to lock down your files.',
                style: text.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Same encryption on all of them. Different levels of convenience.',
                style: text.bodyMedium?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.72),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Tap a plan to see what it includes.',
                style: text.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.5),
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(height: 18),
              _FreeCard(
                expanded: _expanded == _TierKind.free,
                onToggle: () => _toggleExpanded(_TierKind.free),
              ),
              const SizedBox(height: 12),
              _PlusCard(
                annual: _annual,
                onSelectAnnual: (v) => setState(() => _annual = v),
                onPurchase: _mockPurchase,
                expanded: _expanded == _TierKind.plus,
                onToggle: () => _toggleExpanded(_TierKind.plus),
              ),
              const SizedBox(height: 12),
              _LifetimeCard(
                onPurchase: _mockPurchase,
                expanded: _expanded == _TierKind.lifetime,
                onToggle: () => _toggleExpanded(_TierKind.lifetime),
              ),
              const SizedBox(height: 20),
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
                'Prices in USD. Billed through Google Play. Cancel anytime in your Play Store subscriptions.',
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

// ---------------------------------------------------------------------------
// FREE card
// ---------------------------------------------------------------------------

class _FreeCard extends StatelessWidget {
  const _FreeCard({required this.expanded, required this.onToggle});

  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return _TierCard(
      badge: 'FREE',
      price: r'$0 forever',
      priceSub: null,
      features: const [
        'Unlimited encrypted files',
        '1 cloud at a time',
        'Basic magic-link sharing',
        'Full manual control',
      ],
      cta: null,
      recommended: false,
      expanded: expanded,
      onToggle: onToggle,
    );
  }
}

// ---------------------------------------------------------------------------
// PLUS card
// ---------------------------------------------------------------------------

class _PlusCard extends StatelessWidget {
  const _PlusCard({
    required this.annual,
    required this.onSelectAnnual,
    required this.onPurchase,
    required this.expanded,
    required this.onToggle,
  });

  final bool annual;
  final ValueChanged<bool> onSelectAnnual;
  final VoidCallback onPurchase;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final priceLine = annual ? r'$19.99/year' : r'$1.99/month';
    final priceSub =
        annual ? r'That is about $1.66/month. 17% off monthly.' : null;
    final ctaLabel = annual ? 'Start 7-day free trial' : 'Start Plus';

    return _TierCard(
      badge: 'PLUS',
      priceHeader: _PlusToggle(annual: annual, onChanged: onSelectAnnual),
      price: priceLine,
      priceSub: priceSub,
      features: const [
        'Everything in Free, and:',
        'Auto-sync new photos in the background',
        'In-app photo editor',
        'Password-protected shares with custom expiry',
        '30-day recycle bin',
        'Multiple clouds, no soft cap, extra viewer actions',
      ],
      cta: _TierCta(label: ctaLabel, onPressed: onPurchase),
      recommended: true,
      expanded: expanded,
      onToggle: onToggle,
    );
  }
}

class _PlusToggle extends StatelessWidget {
  const _PlusToggle({required this.annual, required this.onChanged});
  final bool annual;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment(value: false, label: Text('Monthly')),
        ButtonSegment(value: true, label: Text('Annual · save 17%')),
      ],
      selected: {annual},
      onSelectionChanged: (s) => onChanged(s.first),
      showSelectedIcon: false,
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// LIFETIME card
// ---------------------------------------------------------------------------

class _LifetimeCard extends StatelessWidget {
  const _LifetimeCard({
    required this.onPurchase,
    required this.expanded,
    required this.onToggle,
  });
  final VoidCallback onPurchase;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return _TierCard(
      badge: 'LIFETIME · Founder\'s Edition',
      price: r'$39 one-time',
      priceStrikethrough: r'$79',
      priceSub: 'Limited to the first 1,000 supporters.',
      featuresIntro: null,
      features: const [
        'Every Plus feature. Forever.',
        "Yours whether we're still around in five years or not.",
      ],
      cta: _TierCta(label: 'Buy Lifetime', onPressed: onPurchase),
      recommended: false,
      expanded: expanded,
      onToggle: onToggle,
    );
  }
}

// ---------------------------------------------------------------------------
// Shared card scaffold
// ---------------------------------------------------------------------------

class _TierCta {
  const _TierCta({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;
}

class _TierCard extends StatelessWidget {
  const _TierCard({
    required this.badge,
    required this.price,
    required this.priceSub,
    required this.features,
    required this.cta,
    required this.recommended,
    required this.expanded,
    required this.onToggle,
    this.priceHeader,
    this.priceStrikethrough,
    this.featuresIntro,
  });

  final String badge;
  final Widget? priceHeader;
  final String price;
  final String? priceStrikethrough;
  final String? priceSub;
  final String? featuresIntro;
  final List<String> features;
  final _TierCta? cta;
  final bool recommended;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final borderColor = recommended
        ? cs.primary
        : cs.outline.withValues(alpha: 0.4);
    return Material(
      color: recommended
          ? cs.surface
          : cs.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: borderColor,
              width: recommended ? 1.6 : 1,
            ),
          ),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: recommended
                            ? cs.primary.withValues(alpha: 0.14)
                            : cs.onSurface.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        badge,
                        style: text.labelSmall?.copyWith(
                          color: recommended ? cs.primary : cs.onSurface,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                    if (recommended) ...[
                      const SizedBox(width: 8),
                      Text(
                        'Recommended',
                        style: text.labelSmall?.copyWith(
                          color: cs.primary.withValues(alpha: 0.85),
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                    const Spacer(),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: ThemeIcon(
                        'caretDown',
                        size: 18,
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (priceHeader != null) ...[
                  priceHeader!,
                  const SizedBox(height: 8),
                ],
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      price,
                      style: text.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (priceStrikethrough != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        priceStrikethrough!,
                        style: text.titleMedium?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.5),
                          decoration: TextDecoration.lineThrough,
                        ),
                      ),
                    ],
                  ],
                ),
                if (priceSub != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    priceSub!,
                    style: text.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.68),
                    ),
                  ),
                ],
                if (expanded) ...[
                  const SizedBox(height: 12),
                  if (featuresIntro != null) ...[
                    Text(
                      featuresIntro!,
                      style: text.labelMedium?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.7),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  for (final f in features)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: ThemeIcon(
                              'checkCircle',
                              selected: true,
                              size: 16,
                              color: recommended
                                  ? cs.primary
                                  : AppColors.success,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              f,
                              style: text.bodyMedium?.copyWith(
                                color: cs.onSurface.withValues(alpha: 0.92),
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                if (cta != null) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: cta!.onPressed,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        backgroundColor: recommended
                            ? cs.primary
                            : cs.primary.withValues(alpha: 0.9),
                        foregroundColor: cs.onPrimary,
                      ),
                      child: Text(
                        cta!.label,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
