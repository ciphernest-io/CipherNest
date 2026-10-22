import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme_controller.dart';
import 'theme_packs.dart';
import 'page_transitions.dart';

// ---------------------------------------------------------------------------
// SEMANTIC SHIM — AppColors stays as static getters that resolve to the live
// theme pack. A handful of widgets still reference AppColors.primary directly
// (gallery viewer's filmstrip border, settings cache slider). They keep
// working without per-site refactor.
// ---------------------------------------------------------------------------

class AppColors {
  static Color get _tokens =>
      ThemePackTokens.forPackMode(
        ThemeController().pack,
        ThemeController().brightness,
      ).accent;

  /// The primary accent of the current pack/mode.
  static Color get primary => _tokens;

  /// Legacy semantic constants. Surfaces and text now come from `Theme.of`,
  /// but these stay for the few hardcoded call-sites that haven't migrated.
  static const Color error = Color(0xFFFF4444);
  static const Color success = Color(0xFF44FF88);
  static const Color warning = Color(0xFFFFAA00);
}

// ---------------------------------------------------------------------------
// TYPOGRAPHY — routes to the active pack's fonts. Bungee Hairline for the
// brand wordmark is the one fixed anchor across every pack.
// ---------------------------------------------------------------------------

class AppTypography {
  static ThemePackTokens get _t => ThemePackTokens.forPackMode(
        ThemeController().pack,
        ThemeController().brightness,
      );

  /// CipherNest wordmark. Always Bungee Hairline weight 800 — the one font
  /// that never changes across packs. Bundled locally (assets/fonts/) so the
  /// splash never paints in the platform fallback while google_fonts fetches.
  static TextStyle brand({double fontSize = 28, Color? color}) {
    return TextStyle(
      fontFamily: 'BungeeHairline',
      fontSize: fontSize,
      fontWeight: FontWeight.w800,
      color: color ?? _t.fg,
      letterSpacing: 2,
    );
  }

  /// Heading style — uses the current pack's title font.
  static TextStyle heading({
    double fontSize = 22,
    FontWeight fontWeight = FontWeight.w600,
    Color? color,
  }) {
    return _packTextStyle(
      _t.titleFontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color ?? _t.fg,
      letterSpacing: _t.titleLetterSpacing,
    );
  }

  /// Body style — uses the current pack's UI font.
  static TextStyle body({
    double fontSize = 14,
    FontWeight fontWeight = FontWeight.w400,
    Color? color,
  }) {
    return _packTextStyle(
      _t.fontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color ?? _t.fg2,
    );
  }
}

/// Direct fontFamily reference against the bundled TTF assets. Every pack
/// font (Hanken Grotesk, IM Fell English, DM Sans, Snowburst One, Carattere,
/// EB Garamond, Chakra Petch, VT323) is declared in pubspec.yaml under its
/// human name, so `fontFamily: 'IM Fell English'` binds to the local asset
/// with zero network round-trip. Kills the FOUC that runtime GoogleFonts
/// downloads were causing on cold install.
TextStyle _packTextStyle(
  String family, {
  required double fontSize,
  required FontWeight fontWeight,
  required Color color,
  double letterSpacing = 0,
}) {
  return TextStyle(
    fontFamily: family,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    letterSpacing: letterSpacing,
  );
}

// ---------------------------------------------------------------------------
// THEME BUILDER — translates a pack + mode into Flutter ThemeData.
// ---------------------------------------------------------------------------

class AppTheme {
  /// Build the [ThemeData] for a given theme pack + brightness mode.
  /// Every visual decision in this method reads from [ThemePackTokens] so
  /// switching packs swaps the whole UI at once.
  static ThemeData build({
    required ThemePack pack,
    required Brightness mode,
  }) {
    final t = ThemePackTokens.forPackMode(pack, mode);

    final colorScheme = ColorScheme(
      brightness: mode,
      primary: t.accent,
      onPrimary: t.onAccent,
      secondary: t.accent,
      onSecondary: t.onAccent,
      error: t.danger,
      onError: t.onAccent,
      surface: t.bg,
      onSurface: t.fg,
      surfaceContainerLowest: t.bg,
      surfaceContainerLow: t.panel,
      surfaceContainer: t.panel,
      surfaceContainerHigh: t.surface,
      surfaceContainerHighest: t.surface2,
      outline: t.hairline,
      outlineVariant: t.hairline,
      scrim: t.scrim,
      tertiary: t.info,
      onTertiary: t.onAccent,
    );

    final titleStyle = _packTextStyle(
      t.titleFontFamily,
      fontSize: 17,
      fontWeight: FontWeight.w600,
      color: t.fg,
      letterSpacing: t.titleLetterSpacing,
    );
    final bodyStyle = _packTextStyle(
      t.fontFamily,
      fontSize: 14,
      fontWeight: FontWeight.w400,
      color: t.fg2,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: mode,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: t.bg,
      canvasColor: t.bg,
      dividerColor: t.hairline,

      appBarTheme: AppBarTheme(
        backgroundColor: t.bg,
        foregroundColor: t.fg,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: titleStyle.copyWith(fontSize: 20),
        // Transparent app bars (viewer, auth flow) make AppBar estimate the
        // status-bar style from transparent-as-black — white clock/battery
        // on a white background in light mode. Pin it to the real mode.
        systemOverlayStyle: mode == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),

      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: t.panel,
        selectedItemColor: t.accent,
        unselectedItemColor: t.fgMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),

      cardTheme: CardThemeData(
        color: t.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.rCard),
        ),
        elevation: 0,
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: t.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.rCardLg),
        ),
        titleTextStyle: titleStyle.copyWith(fontSize: 18),
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.surface,
        contentTextStyle: bodyStyle.copyWith(color: t.fg),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.rCard),
        ),
        behavior: SnackBarBehavior.floating,
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: t.accent,
          foregroundColor: t.onAccent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(t.rCard),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: titleStyle.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: t.accent,
          side: BorderSide(color: t.accent),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(t.rCard),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: t.accent),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: t.accent,
        foregroundColor: t.onAccent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.rCardLg),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(t.rInput),
          borderSide: BorderSide(color: t.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(t.rInput),
          borderSide: BorderSide(color: t.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(t.rInput),
          borderSide: BorderSide(color: t.accent, width: 1.5),
        ),
        labelStyle: bodyStyle,
        hintStyle: bodyStyle.copyWith(color: t.fgFaint),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return t.accent;
          return t.fgMuted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return t.accentSoft;
          return t.hairline;
        }),
      ),

      sliderTheme: SliderThemeData(
        activeTrackColor: t.accent,
        inactiveTrackColor: t.hairline,
        thumbColor: t.accent,
        overlayColor: t.accentFaint,
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(t.rSheet)),
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: t.surface,
        selectedColor: t.accentSoft,
        side: BorderSide(color: t.hairline),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.rPill),
        ),
        labelStyle: bodyStyle.copyWith(color: t.fg),
      ),

      textTheme: TextTheme(
        headlineLarge: _packTextStyle(
          t.titleFontFamily,
          fontSize: 32, fontWeight: FontWeight.w700, color: t.fg,
          letterSpacing: t.titleLetterSpacing,
        ),
        headlineMedium: _packTextStyle(
          t.titleFontFamily,
          fontSize: 28, fontWeight: FontWeight.w700, color: t.fg,
          letterSpacing: t.titleLetterSpacing,
        ),
        headlineSmall: _packTextStyle(
          t.titleFontFamily,
          fontSize: 22, fontWeight: FontWeight.w600, color: t.fg,
          letterSpacing: t.titleLetterSpacing,
        ),
        titleLarge: _packTextStyle(
          t.titleFontFamily,
          fontSize: 17, fontWeight: FontWeight.w600, color: t.fg,
          letterSpacing: t.titleLetterSpacing,
        ),
        titleMedium: _packTextStyle(
          t.titleFontFamily,
          fontSize: 14, fontWeight: FontWeight.w500, color: t.fg,
        ),
        bodyLarge: _packTextStyle(
          t.fontFamily,
          fontSize: 15, fontWeight: FontWeight.w400, color: t.fg2,
        ),
        bodyMedium: _packTextStyle(
          t.fontFamily,
          fontSize: 14, fontWeight: FontWeight.w400, color: t.fg2,
        ),
        bodySmall: _packTextStyle(
          t.fontFamily,
          fontSize: 12, fontWeight: FontWeight.w400, color: t.fgMuted,
        ),
        labelLarge: _packTextStyle(
          t.titleFontFamily,
          fontSize: 13, fontWeight: FontWeight.w600, color: t.fg,
        ),
        labelSmall: _packTextStyle(
          t.fontFamily,
          fontSize: 11, fontWeight: FontWeight.w400, color: t.fgFaint,
        ),
      ),

      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: SlideOverPageTransitionsBuilder(),
          TargetPlatform.iOS: SlideOverPageTransitionsBuilder(),
        },
      ),
    );
  }
}
