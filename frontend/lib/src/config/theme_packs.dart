import 'package:flutter/material.dart';

/// The seven CipherNest theme packs. Each pack swaps color + fonts + corner
/// radius + density + motion + icon style together. Layout and component
/// structure never change — they read tokens from [ThemePackTokens].
///
/// Default is [binary] / [Brightness.dark]. Order here is the order shown
/// in Settings → Appearance.
enum ThemePack { binary, burrow, corporate, alien, paper, garnet, hackerman }

extension ThemePackX on ThemePack {
  /// Stable wire string used in SharedPreferences. Don't rename casually —
  /// renaming orphans existing users' picks.
  String get wire => name;

  /// Human-readable label for Settings.
  String get label {
    switch (this) {
      case ThemePack.binary: return 'Binary';
      case ThemePack.burrow: return 'Burrow';
      case ThemePack.corporate: return 'Corporate';
      case ThemePack.alien: return 'Alien';
      case ThemePack.paper: return 'Paper';
      case ThemePack.garnet: return 'Garnet';
      case ThemePack.hackerman: return 'Hackerman';
    }
  }

  /// One-line tagline shown under the theme name in the picker.
  String get tagline {
    switch (this) {
      case ThemePack.binary: return 'Pure monochrome. The default.';
      case ThemePack.burrow: return 'Earthy soil, clay-amber accent.';
      case ThemePack.corporate: return 'Cool steel slate. Sharp, dense.';
      case ThemePack.alien: return 'Obsidian + gooey lime.';
      case ThemePack.paper: return 'Vellum and gold ink.';
      case ThemePack.garnet: return 'Charcoal + crimson.';
      case ThemePack.hackerman: return 'Midnight terminal. Square + neon.';
    }
  }

  static ThemePack fromWire(String? s) {
    for (final p in ThemePack.values) {
      if (p.wire == s) return p;
    }
    return ThemePack.binary;
  }
}

/// Immutable bundle of every visual token a theme pack defines. The CSS
/// design system uses ~30 custom properties per pack/mode — this is the
/// Dart mirror of that contract. A `ThemeData` is built from these by
/// [AppTheme.build].
@immutable
class ThemePackTokens {
  // ---- surfaces ----
  final Color bg;          // app background
  final Color panel;       // primary container surface
  final Color surface;     // card body
  final Color surface2;    // raised / pressed surfaces
  final Color hairline;    // 1 px dividers
  // ---- text ----
  final Color fg;          // primary text
  final Color fg2;         // secondary text
  final Color fgMuted;     // captions / placeholders
  final Color fgFaint;     // disabled text
  // ---- accent ----
  final Color accent;
  final Color accentPress;
  final Color accentSoft;  // 12–16% accent tint
  final Color accentFaint; //  5–8% accent tint
  final Color onAccent;    // text on accent surface
  // ---- semantics ----
  final Color success;
  final Color warning;
  final Color danger;
  final Color info;
  // ---- scrim / shadow ----
  final Color scrim;
  // ---- corner radii ----
  final double rInput;
  final double rCard;
  final double rCardLg;
  final double rSheet;
  final double rPill;
  final double rIc;
  // ---- density ----
  final double pad;
  final double rowH;
  // ---- typography ----
  final String fontFamily;       // body / UI
  final String titleFontFamily;  // headings (may equal fontFamily)
  final String monoFontFamily;   // numerals / addresses
  final double titleLetterSpacing;
  // ---- motion ----
  final Duration durFast;
  final Duration dur;
  final Duration durSlow;
  final Curve ease;
  final Curve easeOut;
  // ---- per-pack imagery ----
  final String cardArtAsset; // e.g. 'assets/images/themes/card-binary-dark.png'
  final String? appTexAsset; // Hackerman uses a full-app code-rain tex; null elsewhere

  const ThemePackTokens({
    required this.bg,
    required this.panel,
    required this.surface,
    required this.surface2,
    required this.hairline,
    required this.fg,
    required this.fg2,
    required this.fgMuted,
    required this.fgFaint,
    required this.accent,
    required this.accentPress,
    required this.accentSoft,
    required this.accentFaint,
    required this.onAccent,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.scrim,
    required this.rInput,
    required this.rCard,
    required this.rCardLg,
    required this.rSheet,
    required this.rPill,
    required this.rIc,
    required this.pad,
    required this.rowH,
    required this.fontFamily,
    required this.titleFontFamily,
    required this.monoFontFamily,
    required this.titleLetterSpacing,
    required this.durFast,
    required this.dur,
    required this.durSlow,
    required this.ease,
    required this.easeOut,
    required this.cardArtAsset,
    this.appTexAsset,
  });

  static ThemePackTokens forPackMode(ThemePack pack, Brightness mode) {
    switch (pack) {
      case ThemePack.binary:
        return mode == Brightness.dark ? _binaryDark : _binaryLight;
      case ThemePack.burrow:
        return mode == Brightness.dark ? _burrowDark : _burrowLight;
      case ThemePack.corporate:
        return mode == Brightness.dark ? _corporateDark : _corporateLight;
      case ThemePack.alien:
        return mode == Brightness.dark ? _alienDark : _alienLight;
      case ThemePack.paper:
        return mode == Brightness.dark ? _paperDark : _paperLight;
      case ThemePack.garnet:
        return mode == Brightness.dark ? _garnetDark : _garnetLight;
      case ThemePack.hackerman:
        return mode == Brightness.dark ? _hackermanDark : _hackermanLight;
    }
  }
}

// =============================================================================
// SHARED constants — every pack's mode-token block can reuse these
// =============================================================================

const _darkScrim = Color(0x95000000); // rgba(0,0,0,0.58)
const _lightScrim = Color(0x66181612); // rgba(24,22,18,0.40)

const _ease = Cubic(0.4, 0, 0.2, 1);
const _easeOut = Cubic(0.2, 0.6, 0.2, 1);

// =============================================================================
// 1 · BINARY  (default) — monochrome
// =============================================================================

final _binaryDark = ThemePackTokens(
  bg: const Color(0xFF0E0E0F), panel: const Color(0xFF161617),
  surface: const Color(0xFF1D1D1F), surface2: const Color(0xFF262628),
  hairline: const Color(0xFF2E2E31),
  fg: const Color(0xFFF4F4F5), fg2: const Color(0xFFC5C5C8),
  fgMuted: const Color(0xFF8C8C91), fgFaint: const Color(0xFF5A5A5E),
  accent: const Color(0xFFE6E6E8), accentPress: const Color(0xFFCFCFD2),
  accentSoft: const Color(0x1FE6E6E8), accentFaint: const Color(0x0DE6E6E8),
  onAccent: const Color(0xFF161617),
  success: const Color(0xFFC5C5C8), warning: const Color(0xFFC5C5C8),
  danger: const Color(0xFFE6E6E8), info: const Color(0xFF9A9AA0),
  scrim: _darkScrim,
  rInput: 10, rCard: 14, rCardLg: 18, rSheet: 24, rPill: 999, rIc: 12,
  pad: 18, rowH: 60,
  fontFamily: 'Hanken Grotesk',
  titleFontFamily: 'Hanken Grotesk',
  monoFontFamily: 'Hanken Grotesk',
  titleLetterSpacing: -0.02,
  durFast: const Duration(milliseconds: 130),
  dur: const Duration(milliseconds: 180),
  durSlow: const Duration(milliseconds: 260),
  ease: _ease, easeOut: _easeOut,
  cardArtAsset: 'assets/images/themes/card-binary-dark.png',
);

final _binaryLight = ThemePackTokens(
  bg: const Color(0xFFF4F4F3), panel: const Color(0xFFECECEB),
  surface: const Color(0xFFFFFFFF), surface2: const Color(0xFFF0F0EF),
  hairline: const Color(0xFFE2E2E0),
  fg: const Color(0xFF1A1A1C), fg2: const Color(0xFF46464A),
  fgMuted: const Color(0xFF76767A), fgFaint: const Color(0xFFA8A8AC),
  accent: const Color(0xFF1A1A1C), accentPress: const Color(0xFF333336),
  accentSoft: const Color(0x141A1A1C), accentFaint: const Color(0x0A1A1A1C),
  onAccent: const Color(0xFFFFFFFF),
  success: const Color(0xFF46464A), warning: const Color(0xFF46464A),
  danger: const Color(0xFF1A1A1C), info: const Color(0xFF76767A),
  scrim: _lightScrim,
  rInput: 10, rCard: 14, rCardLg: 18, rSheet: 24, rPill: 999, rIc: 12,
  pad: 18, rowH: 60,
  fontFamily: 'Hanken Grotesk',
  titleFontFamily: 'Hanken Grotesk',
  monoFontFamily: 'Hanken Grotesk',
  titleLetterSpacing: -0.02,
  durFast: const Duration(milliseconds: 130),
  dur: const Duration(milliseconds: 180),
  durSlow: const Duration(milliseconds: 260),
  ease: _ease, easeOut: _easeOut,
  cardArtAsset: 'assets/images/themes/card-binary-light.png',
);

// =============================================================================
// 2 · BURROW — earthy soil, clay-amber, very round
// =============================================================================

final _burrowDark = ThemePackTokens(
  bg: const Color(0xFF120B06), panel: const Color(0xFF1A1109),
  surface: const Color(0xFF22160C), surface2: const Color(0xFF2D1E10),
  hairline: const Color(0xFF392815),
  fg: const Color(0xFFDCCBAD), fg2: const Color(0xFFAB9876),
  fgMuted: const Color(0xFF7C6B4E), fgFaint: const Color(0xFF564833),
  accent: const Color(0xFFBC8645), accentPress: const Color(0xFFA4733A),
  accentSoft: const Color(0x26BC8645), accentFaint: const Color(0x12BC8645),
  onAccent: const Color(0xFF170D03),
  success: const Color(0xFF7E8A4A), warning: const Color(0xFFC49A42),
  danger: const Color(0xFFB66440), info: const Color(0xFF8C7B58),
  scrim: _darkScrim,
  rInput: 16, rCard: 24, rCardLg: 28, rSheet: 30, rPill: 999, rIc: 18,
  pad: 20, rowH: 62,
  fontFamily: 'IM Fell English',
  titleFontFamily: 'IM Fell English',
  monoFontFamily: 'IM Fell English',
  titleLetterSpacing: 0,
  durFast: const Duration(milliseconds: 170),
  dur: const Duration(milliseconds: 240),
  durSlow: const Duration(milliseconds: 340),
  ease: const Cubic(0.34, 0.1, 0.2, 1), easeOut: _easeOut,
  cardArtAsset: 'assets/images/themes/card-earth-dark.png',
);

final _burrowLight = ThemePackTokens(
  bg: const Color(0xFFDED7C8), panel: const Color(0xFFD2C9B6),
  surface: const Color(0xFFE6DFD0), surface2: const Color(0xFFD8CFBC),
  hairline: const Color(0xFFC4B9A2),
  fg: const Color(0xFF3A3026), fg2: const Color(0xFF5E5444),
  fgMuted: const Color(0xFF867B68), fgFaint: const Color(0xFFA99D86),
  accent: const Color(0xFF8A4A24), accentPress: const Color(0xFF763F1F),
  accentSoft: const Color(0x1F8A4A24), accentFaint: const Color(0x0F8A4A24),
  onAccent: const Color(0xFFFFFFFF),
  success: const Color(0xFF566E3C), warning: const Color(0xFF90681C),
  danger: const Color(0xFF964834), info: const Color(0xFF665B44),
  scrim: _lightScrim,
  rInput: 16, rCard: 24, rCardLg: 28, rSheet: 30, rPill: 999, rIc: 18,
  pad: 20, rowH: 62,
  fontFamily: 'IM Fell English',
  titleFontFamily: 'IM Fell English',
  monoFontFamily: 'IM Fell English',
  titleLetterSpacing: 0,
  durFast: const Duration(milliseconds: 170),
  dur: const Duration(milliseconds: 240),
  durSlow: const Duration(milliseconds: 340),
  ease: const Cubic(0.34, 0.1, 0.2, 1), easeOut: _easeOut,
  cardArtAsset: 'assets/images/themes/card-earth-light.png',
);

// =============================================================================
// 3 · CORPORATE — steel slate. Google Sans Flex substituted with DM Sans.
// =============================================================================

final _corporateDark = ThemePackTokens(
  bg: const Color(0xFF0C0D0F), panel: const Color(0xFF131519),
  surface: const Color(0xFF191B1F), surface2: const Color(0xFF212429),
  hairline: const Color(0xFF2A2D33),
  fg: const Color(0xFFF5F6F8), fg2: const Color(0xFFBCC1C9),
  fgMuted: const Color(0xFF7E848E), fgFaint: const Color(0xFF4F555E),
  accent: const Color(0xFF5E92F5), accentPress: const Color(0xFF477BDE),
  accentSoft: const Color(0x265E92F5), accentFaint: const Color(0x125E92F5),
  onAccent: const Color(0xFF06101F),
  success: const Color(0xFF3FB07E), warning: const Color(0xFFE0A53A),
  danger: const Color(0xFFE25C54), info: const Color(0xFF5E92F5),
  scrim: _darkScrim,
  rInput: 6, rCard: 8, rCardLg: 10, rSheet: 14, rPill: 7, rIc: 7,
  pad: 15, rowH: 54,
  fontFamily: 'DM Sans',
  titleFontFamily: 'DM Sans',
  monoFontFamily: 'Spline Sans Mono',
  titleLetterSpacing: -0.03,
  durFast: const Duration(milliseconds: 90),
  dur: const Duration(milliseconds: 130),
  durSlow: const Duration(milliseconds: 200),
  ease: const Cubic(0.4, 0, 0.1, 1),
  easeOut: const Cubic(0.2, 0.7, 0.3, 1),
  cardArtAsset: 'assets/images/themes/card-skyline-dark.png',
);

final _corporateLight = ThemePackTokens(
  bg: const Color(0xFFF4F6F9), panel: const Color(0xFFEAEEF3),
  surface: const Color(0xFFFFFFFF), surface2: const Color(0xFFEEF1F5),
  hairline: const Color(0xFFDCE2EA),
  fg: const Color(0xFF10141A), fg2: const Color(0xFF3A434F),
  fgMuted: const Color(0xFF6B7480), fgFaint: const Color(0xFF9AA3AF),
  accent: const Color(0xFF2F66C0), accentPress: const Color(0xFF27559F),
  accentSoft: const Color(0x1F2F66C0), accentFaint: const Color(0x0F2F66C0),
  onAccent: const Color(0xFFFFFFFF),
  success: const Color(0xFF318A66), warning: const Color(0xFFB57F1F),
  danger: const Color(0xFFC24E46), info: const Color(0xFF2F66C0),
  scrim: _lightScrim,
  rInput: 6, rCard: 8, rCardLg: 10, rSheet: 14, rPill: 7, rIc: 7,
  pad: 15, rowH: 54,
  fontFamily: 'DM Sans',
  titleFontFamily: 'DM Sans',
  monoFontFamily: 'Spline Sans Mono',
  titleLetterSpacing: -0.03,
  durFast: const Duration(milliseconds: 90),
  dur: const Duration(milliseconds: 130),
  durSlow: const Duration(milliseconds: 200),
  ease: const Cubic(0.4, 0, 0.1, 1),
  easeOut: const Cubic(0.2, 0.7, 0.3, 1),
  cardArtAsset: 'assets/images/themes/card-skyline-light.png',
);

// =============================================================================
// 4 · ALIEN — obsidian + gooey lime
// =============================================================================

final _alienDark = ThemePackTokens(
  bg: const Color(0xFF090A11), panel: const Color(0xFF0F1019),
  surface: const Color(0xFF141526), surface2: const Color(0xFF1C1E33),
  hairline: const Color(0xFF262A45),
  fg: const Color(0xFFE8F0DC), fg2: const Color(0xFFAEBCA0),
  fgMuted: const Color(0xFF79866C), fgFaint: const Color(0xFF4C5640),
  accent: const Color(0xFF93E03C), accentPress: const Color(0xFF7FC92F),
  accentSoft: const Color(0x2993E03C), accentFaint: const Color(0x1493E03C),
  onAccent: const Color(0xFF0A1503),
  success: const Color(0xFF93E03C), warning: const Color(0xFFE0C83C),
  danger: const Color(0xFFE0556E), info: const Color(0xFF6AC0E0),
  scrim: _darkScrim,
  rInput: 13, rCard: 20, rCardLg: 24, rSheet: 26, rPill: 999, rIc: 16,
  pad: 18, rowH: 60,
  fontFamily: 'Snowburst One',
  titleFontFamily: 'Snowburst One',
  monoFontFamily: 'Snowburst One',
  titleLetterSpacing: 0.01,
  durFast: const Duration(milliseconds: 200),
  dur: const Duration(milliseconds: 300),
  durSlow: const Duration(milliseconds: 420),
  ease: const Cubic(0.2, 0.6, 0.2, 1),
  easeOut: const Cubic(0.16, 0.8, 0.3, 1),
  cardArtAsset: 'assets/images/themes/card-ufo-dark.png',
);

final _alienLight = ThemePackTokens(
  bg: const Color(0xFFE5E9F2), panel: const Color(0xFFD9DFEC),
  surface: const Color(0xFFF1F4FB), surface2: const Color(0xFFE4EAF5),
  hairline: const Color(0xFFCCD5E6),
  fg: const Color(0xFF101522), fg2: const Color(0xFF39435A),
  fgMuted: const Color(0xFF697490), fgFaint: const Color(0xFF98A2BC),
  accent: const Color(0xFF1FA046), accentPress: const Color(0xFF198739),
  accentSoft: const Color(0x241FA046), accentFaint: const Color(0x0F1FA046),
  onAccent: const Color(0xFFFFFFFF),
  success: const Color(0xFF1FA046), warning: const Color(0xFFB07A1C),
  danger: const Color(0xFFC24E62), info: const Color(0xFF3F77C0),
  scrim: _lightScrim,
  rInput: 13, rCard: 20, rCardLg: 24, rSheet: 26, rPill: 999, rIc: 16,
  pad: 18, rowH: 60,
  fontFamily: 'Snowburst One',
  titleFontFamily: 'Snowburst One',
  monoFontFamily: 'Snowburst One',
  titleLetterSpacing: 0.01,
  durFast: const Duration(milliseconds: 200),
  dur: const Duration(milliseconds: 300),
  durSlow: const Duration(milliseconds: 420),
  ease: const Cubic(0.2, 0.6, 0.2, 1),
  easeOut: const Cubic(0.16, 0.8, 0.3, 1),
  cardArtAsset: 'assets/images/themes/card-ufo-light.png',
);

// =============================================================================
// 5 · PAPER — parchment by day, scriptorium ink by night
// =============================================================================

final _paperLight = ThemePackTokens(
  bg: const Color(0xFFF7F3E9), panel: const Color(0xFFF1ECDD),
  surface: const Color(0xFFFCFAF2), surface2: const Color(0xFFF2EDDF),
  hairline: const Color(0xFFE2D9C4),
  fg: const Color(0xFF241F18), fg2: const Color(0xFF4E463A),
  fgMuted: const Color(0xFF857C6B), fgFaint: const Color(0xFFB3A88F),
  accent: const Color(0xFF8A5A2C), accentPress: const Color(0xFF744A23),
  accentSoft: const Color(0x218A5A2C), accentFaint: const Color(0x0F8A5A2C),
  onAccent: const Color(0xFFFFFFFF),
  success: const Color(0xFF5E8A4E), warning: const Color(0xFFB5862A),
  danger: const Color(0xFFA8492E), info: const Color(0xFF8A6A3C),
  scrim: _lightScrim,
  rInput: 8, rCard: 11, rCardLg: 14, rSheet: 18, rPill: 999, rIc: 10,
  pad: 19, rowH: 60,
  fontFamily: 'Carattere',
  titleFontFamily: 'Carattere',
  monoFontFamily: 'EB Garamond',
  titleLetterSpacing: 0,
  durFast: const Duration(milliseconds: 150),
  dur: const Duration(milliseconds: 220),
  durSlow: const Duration(milliseconds: 320),
  ease: const Cubic(0.3, 0.2, 0.2, 1), easeOut: _easeOut,
  cardArtAsset: 'assets/images/themes/card-news-light.png',
);

final _paperDark = ThemePackTokens(
  bg: const Color(0xFF050505), panel: const Color(0xFF0C0B0A),
  surface: const Color(0xFF121110), surface2: const Color(0xFF1A1816),
  hairline: const Color(0xFF262320),
  fg: const Color(0xFFE8E0CE), fg2: const Color(0xFFB5AC98),
  fgMuted: const Color(0xFF807868), fgFaint: const Color(0xFF524C41),
  accent: const Color(0xFFCBA15A), accentPress: const Color(0xFFB28C49),
  accentSoft: const Color(0x26CBA15A), accentFaint: const Color(0x12CBA15A),
  onAccent: const Color(0xFF160F05),
  success: const Color(0xFF86A85E), warning: const Color(0xFFCDA14C),
  danger: const Color(0xFFC2613C), info: const Color(0xFFC99A55),
  scrim: _darkScrim,
  rInput: 8, rCard: 11, rCardLg: 14, rSheet: 18, rPill: 999, rIc: 10,
  pad: 19, rowH: 60,
  fontFamily: 'Carattere',
  titleFontFamily: 'Carattere',
  monoFontFamily: 'EB Garamond',
  titleLetterSpacing: 0,
  durFast: const Duration(milliseconds: 150),
  dur: const Duration(milliseconds: 220),
  durSlow: const Duration(milliseconds: 320),
  ease: const Cubic(0.3, 0.2, 0.2, 1), easeOut: _easeOut,
  cardArtAsset: 'assets/images/themes/card-news-dark.png',
);

// =============================================================================
// 6 · GARNET — charcoal + crimson
// =============================================================================

final _garnetDark = ThemePackTokens(
  bg: const Color(0xFF120E0F), panel: const Color(0xFF1B1517),
  surface: const Color(0xFF231B1D), surface2: const Color(0xFF2C2225),
  hairline: const Color(0xFF34292C),
  fg: const Color(0xFFF4ECEC), fg2: const Color(0xFFC8B9B9),
  fgMuted: const Color(0xFF938384), fgFaint: const Color(0xFF615153),
  accent: const Color(0xFFC8324C), accentPress: const Color(0xFFAE2A41),
  accentSoft: const Color(0x29C8324C), accentFaint: const Color(0x14C8324C),
  onAccent: const Color(0xFFFFFFFF),
  success: const Color(0xFF5AA67E), warning: const Color(0xFFE0B44C),
  danger: const Color(0xFFE07A3C), info: const Color(0xFF6E94C4),
  scrim: _darkScrim,
  rInput: 8, rCard: 11, rCardLg: 15, rSheet: 20, rPill: 999, rIc: 10,
  pad: 18, rowH: 58,
  fontFamily: 'Chakra Petch',
  titleFontFamily: 'Chakra Petch',
  monoFontFamily: 'Chakra Petch',
  titleLetterSpacing: -0.01,
  durFast: const Duration(milliseconds: 120),
  dur: const Duration(milliseconds: 170),
  durSlow: const Duration(milliseconds: 280),
  ease: _ease, easeOut: _easeOut,
  cardArtAsset: 'assets/images/themes/card-garnet-dark.png',
);

final _garnetLight = ThemePackTokens(
  bg: const Color(0xFFF7F1F0), panel: const Color(0xFFEFE6E5),
  surface: const Color(0xFFFFFFFF), surface2: const Color(0xFFF3E9E8),
  hairline: const Color(0xFFE6D7D6),
  fg: const Color(0xFF1C1314), fg2: const Color(0xFF46383A),
  fgMuted: const Color(0xFF776668), fgFaint: const Color(0xFFA89698),
  accent: const Color(0xFFB5253F), accentPress: const Color(0xFF9C1F36),
  accentSoft: const Color(0x1FB5253F), accentFaint: const Color(0x0FB5253F),
  onAccent: const Color(0xFFFFFFFF),
  success: const Color(0xFF3E8A62), warning: const Color(0xFFC0851F),
  danger: const Color(0xFFD2691E), info: const Color(0xFF46739F),
  scrim: _lightScrim,
  rInput: 8, rCard: 11, rCardLg: 15, rSheet: 20, rPill: 999, rIc: 10,
  pad: 18, rowH: 58,
  fontFamily: 'Chakra Petch',
  titleFontFamily: 'Chakra Petch',
  monoFontFamily: 'Chakra Petch',
  titleLetterSpacing: -0.01,
  durFast: const Duration(milliseconds: 120),
  dur: const Duration(milliseconds: 170),
  durSlow: const Duration(milliseconds: 280),
  ease: _ease, easeOut: _easeOut,
  cardArtAsset: 'assets/images/themes/card-garnet-light.png',
);

// =============================================================================
// 7 · HACKERMAN — midnight terminal. Square corners, neon green, code rain.
// =============================================================================

final _hackermanDark = ThemePackTokens(
  bg: const Color(0xFF020503), panel: const Color(0xFF04140A),
  surface: const Color(0xFF06180C), surface2: const Color(0xFF0A2412),
  hairline: const Color(0xFF10401F),
  fg: const Color(0xFF5BFF8F), fg2: const Color(0xFF33D96A),
  fgMuted: const Color(0xFF1E9B47), fgFaint: const Color(0xFF12612D),
  accent: const Color(0xFF2BFF55), accentPress: const Color(0xFF16E840),
  accentSoft: const Color(0x2E2BFF55), accentFaint: const Color(0x142BFF55),
  onAccent: const Color(0xFF001505),
  success: const Color(0xFF2BFF55), warning: const Color(0xFFD6FF3C),
  danger: const Color(0xFFFF4D4D), info: const Color(0xFF3CFFE0),
  scrim: _darkScrim,
  rInput: 0, rCard: 0, rCardLg: 0, rSheet: 0, rPill: 0, rIc: 0,
  pad: 16, rowH: 54,
  fontFamily: 'VT323',
  titleFontFamily: 'VT323',
  monoFontFamily: 'VT323',
  titleLetterSpacing: 0.02,
  durFast: const Duration(milliseconds: 60),
  dur: const Duration(milliseconds: 90),
  durSlow: const Duration(milliseconds: 160),
  ease: const Cubic(0.2, 0, 0, 1), easeOut: const Cubic(0.2, 0, 0, 1),
  cardArtAsset: 'assets/images/themes/card-matrix-dark.png',
  appTexAsset: 'assets/images/themes/hacker-rain-dark.png',
);

final _hackermanLight = ThemePackTokens(
  bg: const Color(0xFFD6F0DA), panel: const Color(0xFFC6E8CC),
  surface: const Color(0xFFE2F5E5), surface2: const Color(0xFFCFEDD4),
  hairline: const Color(0xFF9FD4A8),
  fg: const Color(0xFF04210E), fg2: const Color(0xFF0E5223),
  fgMuted: const Color(0xFF1E7D3C), fgFaint: const Color(0xFF56A36E),
  accent: const Color(0xFF04C23A), accentPress: const Color(0xFF03A330),
  accentSoft: const Color(0x2904C23A), accentFaint: const Color(0x1204C23A),
  onAccent: const Color(0xFFF0FFF2),
  success: const Color(0xFF04C23A), warning: const Color(0xFF8A9A00),
  danger: const Color(0xFFD03030), info: const Color(0xFF0AA8A8),
  scrim: _lightScrim,
  rInput: 0, rCard: 0, rCardLg: 0, rSheet: 0, rPill: 0, rIc: 0,
  pad: 16, rowH: 54,
  fontFamily: 'VT323',
  titleFontFamily: 'VT323',
  monoFontFamily: 'VT323',
  titleLetterSpacing: 0.02,
  durFast: const Duration(milliseconds: 60),
  dur: const Duration(milliseconds: 90),
  durSlow: const Duration(milliseconds: 160),
  ease: const Cubic(0.2, 0, 0, 1), easeOut: const Cubic(0.2, 0, 0, 1),
  cardArtAsset: 'assets/images/themes/card-matrix-light.png',
  appTexAsset: 'assets/images/themes/hacker-rain-light.png',
);
