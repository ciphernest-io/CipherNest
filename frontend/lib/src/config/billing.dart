// RevenueCat configuration.
//
// The PUBLIC Android SDK key. It is designed to ship inside the binary and is
// safe in a public repository — it can only read offerings and attribute
// purchases for this app. The SECRET key must never appear here, in the app,
// or in the repo.
//
// Set 2026-09-29 (plan step 4A). While this is empty, BillingService refuses
// to configure the SDK and nothing contacts RevenueCat at all, which is how
// the dependency shipped before the dashboard existed.
const String kRevenueCatPublicKey = 'goog_fTENYRWNmITgJjbpqkeXLYBUHXW';

/// The entitlement identifier configured in the RevenueCat dashboard. Must
/// match exactly, or every user reads as Free.
const String kPlusEntitlementId = 'plus';
