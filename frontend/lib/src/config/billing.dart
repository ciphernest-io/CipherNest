// RevenueCat configuration.
//
// The PUBLIC Android SDK key. It is designed to ship inside the binary and is
// safe in a public repository — it can only read offerings and attribute
// purchases for this app. The SECRET key must never appear here, in the app,
// or in the repo.
//
// DELIBERATELY EMPTY for the first closed-track upload.
//
// The real key is goog_fTENYRWNmITgJjbpqkeXLYBUHXW (plan step 4A). It is NOT
// installed yet, and the ordering is the reason:
//
//   * Play will not let you create in-app products until a build exists on a
//     track, so the first upload necessarily precedes the products.
//   * With the key live, Purchases.configure() fires the moment the paywall
//     opens, which every new user does during onboarding. That sends the
//     billing ID to a third party.
//   * So a build carrying the key would have to declare "Device or other IDs"
//     on the Play Data Safety form, for a billing feature that cannot even
//     function because the offering is empty. Declaring collection for a
//     dead feature is a worse answer than not collecting.
//
// Install the key in the build that ships AFTER step 4B to 4E, and update the
// Data Safety form in that same release. While it is empty, BillingService
// refuses to configure the SDK and nothing contacts RevenueCat at all.
const String kRevenueCatPublicKey = '';

/// The entitlement identifier configured in the RevenueCat dashboard. Must
/// match exactly, or every user reads as Free.
const String kPlusEntitlementId = 'plus';
