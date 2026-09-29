// RevenueCat configuration.
//
// The PUBLIC Android SDK key. It is designed to ship inside the binary and is
// safe in a public repository — it can only read offerings and attribute
// purchases for this app. The SECRET key must never appear here, in the app,
// or in the repo.
//
// Empty until the RevenueCat project exists (REVENUECAT_PLAN.md step 4).
// While it is empty, BillingService refuses to configure the SDK, so nothing
// contacts RevenueCat at all. That is deliberate: the dependency can be
// compiled in and shipped before the dashboard is wired without any traffic
// leaving the device.
const String kRevenueCatPublicKey = '';

/// The entitlement identifier configured in the RevenueCat dashboard. Must
/// match exactly, or every user reads as Free.
const String kPlusEntitlementId = 'plus';
