/// Single source of truth for the user-facing app version label.
///
/// Kept in one place so the gallery Menu tab and the Settings footer can
/// never drift apart again (they previously read "v0.5.0 Beta" and
/// "v1.0.0 Beta"). Update this to match `pubspec.yaml` `version:` on release.
const String kAppVersionLabel = 'CipherNest v1.0.1';

/// Deep-link anchors: the gallery Menu passes one of these as the route
/// argument so [SettingsScreen] opens straight to that category page.
const String kSettingsGallerySection = 'gallery';
const String kSettingsBackupSection = 'backup';
const String kSettingsMusicSection = 'music';
