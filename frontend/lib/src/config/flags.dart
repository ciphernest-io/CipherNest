// Build-time feature flags.
//
// kPaywallEnabled gates whether any flow routes to the paywall at all.
//
// Stays TRUE. The earlier note here said to set it false for the v1.0 AAB and
// flip it back in v1.1; that advice is obsolete now RevenueCat is wired
// (2026-09-29). Plus removes exactly one thing, the 1,000-file cap in
// FreeTierGuard, so the paywall needs a real purchase path.
//
// Setting it false makes isPlus return true for everyone, i.e. gives the app
// away. It is a kill switch, not a launch toggle.
const bool kPaywallEnabled = true;
