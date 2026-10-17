// RevenueCat configuration.
//
// The PUBLIC Android SDK key. It is designed to ship inside the binary and is
// safe in a public repository — it can only read offerings and attribute
// purchases for this app. The SECRET key must never appear here, in the app,
// or in the repo.
//
// The PRODUCTION Google Play SDK key, installed 2026-09-30 once the Play
// products, entitlement and offering existed (plan step 4 complete).
//
// This must be the `goog_` PUBLIC Play key and nothing else. RevenueCat's
// Test Store key is for local development only and a release build that
// carries one CRASHES on configure, by RevenueCat's design. There is a test
// in test/services/billing_service_test.dart that fails the build if this
// value is ever not a goog_ key.
//
// Installing this key means the app now contacts RevenueCat when the paywall
// opens, so the Play Data Safety form must be updated in the same release
// (see BILLING_LAUNCH_CHECKLIST.md). It answered "No" only while this was
// empty.
const String kRevenueCatPublicKey = 'goog_fTENYRWNmITgJjbpqkeXLYBUHXW';

/// The entitlement identifier configured in the RevenueCat dashboard. Must
/// match exactly, or every user reads as Free.
const String kPlusEntitlementId = 'plus';

/// How long a cached entitlement is honoured past its expiry when a
/// verification was ATTEMPTED and failed.
///
/// This exists for one case only: a subscriber whose renewal almost certainly
/// went through, who happens to have no signal at the moment the old period
/// ends. It is NOT a grace period for payment failure — Play's own 3-day
/// grace already extends `expirationDate` for that, so RevenueCat reports the
/// entitlement as still active and this never comes into play.
///
/// If RevenueCat answers and says inactive, the user is Free immediately and
/// this window is not consulted.
const Duration kOfflineTolerance = Duration(hours: 48);

/// Minimum gap between entitlement verifications on app RESUME.
///
/// Resume fires every time the user switches away and back, so verifying
/// unconditionally would mean dozens of requests an hour. Cold start always
/// verifies, and a resume past expiry verifies regardless of this gap.
const Duration kResumeMinGap = Duration(minutes: 15);

/// SharedPreferences key marking that the signup paywall was reached and not
/// yet left. A kill on the paywall used to resume at cloud selection with the
/// step silently skipped; the login router reads this and returns to the
/// paywall instead. Cleared by every exit from the paywall.
const String kPaywallPendingPrefKey = 'paywall_pending_v1';
