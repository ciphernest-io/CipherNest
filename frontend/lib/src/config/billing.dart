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
