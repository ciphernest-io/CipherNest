import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ---------------------------------------------------------------------------
// ACCENT THEMES
// ---------------------------------------------------------------------------

enum AccentTheme { acidGreen, electricOrange, cyanTech, magentaNeon }

class AccentColors {
  final Color primary;
  final Color muted;

  const AccentColors({required this.primary, required this.muted});

  static const acidGreen = AccentColors(
    primary: Color(0xFFBBFF00),
    muted: Color(0xFF6B9400),
  );
  static const electricOrange = AccentColors(
    primary: Color(0xFFFFAA00),
    muted: Color(0xFF996600),
  );
  static const cyanTech = AccentColors(
    primary: Color(0xFF00FFEE),
    muted: Color(0xFF009988),
  );
  static const magentaNeon = AccentColors(
    primary: Color(0xFFFF00BB),
    muted: Color(0xFF990070),
  );

  static AccentColors fromTheme(AccentTheme theme) {
    switch (theme) {
      case AccentTheme.acidGreen:
        return acidGreen;
      case AccentTheme.electricOrange:
        return electricOrange;
      case AccentTheme.cyanTech:
        return cyanTech;
      case AccentTheme.magentaNeon:
        return magentaNeon;
    }
  }
}

// ---------------------------------------------------------------------------
// SEMANTIC TOKENS  (kept as statics so old `AppColors.xxx` references compile
// while screens are migrated; new code should read from Theme/ColorScheme)
// ---------------------------------------------------------------------------

class AppColors {
  // Dark mode defaults (legacy compatibility)
  static const Color background = Color(0xFF000000);
  static const Color surface = Color(0xFF1F1F1F);
  static const Color primary = Color(0xFFBBFF00); // acid green default
  static const Color primaryMuted = Color(0xFF6B9400);
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFE0E0E0);
  static const Color divider = Color(0xFF2A2A2A);

  // Semantic accents (fixed, not theme-dependent)
  static const Color error = Color(0xFFFF4444);
  static const Color success = Color(0xFF44FF88);
  static const Color warning = Color(0xFFFFAA00);
}

// ---------------------------------------------------------------------------
// TYPOGRAPHY
// ---------------------------------------------------------------------------

class AppTypography {
  /// Brand logo font — used wherever "Ciphernest" appears as a logo/header.
  static TextStyle brand({double fontSize = 28, Color? color}) {
    return GoogleFonts.bungeeHairline(
      fontSize: fontSize,
      fontWeight: FontWeight.w400,
      color: color ?? AppColors.textPrimary,
      letterSpacing: 2,
    );
  }

  /// Headings — clean geometric sans.
  static TextStyle heading({
    double fontSize = 22,
    FontWeight fontWeight = FontWeight.w600,
    Color? color,
  }) {
    return GoogleFonts.spaceGrotesk(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color ?? AppColors.textPrimary,
    );
  }

  /// Body & metadata — monospace terminal vibe.
  static TextStyle body({
    double fontSize = 14,
    FontWeight fontWeight = FontWeight.w400,
    Color? color,
  }) {
    return GoogleFonts.spaceMono(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color ?? AppColors.textSecondary,
    );
  }
}

// ---------------------------------------------------------------------------
// THEME BUILDER
// ---------------------------------------------------------------------------

class AppTheme {
  static ThemeData build({
    required Brightness brightness,
    required AccentTheme accent,
  }) {
    final isDark = brightness == Brightness.dark;
    final accentColors = AccentColors.fromTheme(accent);

    final scaffoldBg = isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    final surfaceColor = isDark ? const Color(0xFF1F1F1F) : const Color(0xFFE0E0E0);
    final headingColor = isDark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
    final bodyColor = isDark ? const Color(0xFFE0E0E0) : const Color(0xFF424242);
    final dividerColor = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFBDBDBD);

    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: accentColors.primary,
      onPrimary: Colors.black,
      secondary: accentColors.muted,
      onSecondary: Colors.white,
      error: AppColors.error,
      onError: Colors.white,
      surface: surfaceColor,
      onSurface: headingColor,
      surfaceContainerHighest: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFD0D0D0),
      outline: dividerColor,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: scaffoldBg,
      dividerColor: dividerColor,

      // AppBar
      appBarTheme: AppBarTheme(
        backgroundColor: scaffoldBg,
        foregroundColor: headingColor,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.spaceGrotesk(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: headingColor,
        ),
      ),

      // Bottom nav
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: surfaceColor,
        selectedItemColor: accentColors.primary,
        unselectedItemColor: bodyColor.withAlpha(120),
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),

      // Cards & containers
      cardTheme: CardThemeData(
        color: surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        elevation: 0,
      ),

      // Dialogs
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titleTextStyle: GoogleFonts.spaceGrotesk(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: headingColor,
        ),
      ),

      // Snackbar
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceColor,
        contentTextStyle: GoogleFonts.spaceMono(fontSize: 13, color: headingColor),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),

      // Buttons
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accentColors.primary,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: GoogleFonts.spaceGrotesk(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: accentColors.primary,
          side: BorderSide(color: accentColors.primary),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accentColors.primary),
      ),

      // Floating Action Button
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: accentColors.primary,
        foregroundColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),

      // Input fields
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceColor,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: dividerColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: dividerColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: accentColors.primary, width: 1.5),
        ),
        labelStyle: GoogleFonts.spaceMono(color: bodyColor),
        hintStyle: GoogleFonts.spaceMono(color: bodyColor.withAlpha(100)),
      ),

      // Switch
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return accentColors.primary;
          return bodyColor;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return accentColors.primary.withAlpha(80);
          return dividerColor;
        }),
      ),

      // Slider
      sliderTheme: SliderThemeData(
        activeTrackColor: accentColors.primary,
        inactiveTrackColor: dividerColor,
        thumbColor: accentColors.primary,
        overlayColor: accentColors.primary.withAlpha(40),
      ),

      // Bottom sheet
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surfaceColor,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),

      // Text theme
      textTheme: TextTheme(
        headlineLarge: GoogleFonts.spaceGrotesk(
          fontSize: 30, fontWeight: FontWeight.w700, color: headingColor,
        ),
        headlineMedium: GoogleFonts.spaceGrotesk(
          fontSize: 22, fontWeight: FontWeight.w600, color: headingColor,
        ),
        headlineSmall: GoogleFonts.spaceGrotesk(
          fontSize: 18, fontWeight: FontWeight.w600, color: headingColor,
        ),
        titleLarge: GoogleFonts.spaceGrotesk(
          fontSize: 16, fontWeight: FontWeight.w600, color: headingColor,
        ),
        titleMedium: GoogleFonts.spaceGrotesk(
          fontSize: 14, fontWeight: FontWeight.w500, color: headingColor,
        ),
        bodyLarge: GoogleFonts.spaceMono(
          fontSize: 15, fontWeight: FontWeight.w400, color: bodyColor,
        ),
        bodyMedium: GoogleFonts.spaceMono(
          fontSize: 13, fontWeight: FontWeight.w400, color: bodyColor,
        ),
        bodySmall: GoogleFonts.spaceMono(
          fontSize: 11, fontWeight: FontWeight.w400, color: bodyColor.withAlpha(180),
        ),
        labelLarge: GoogleFonts.spaceGrotesk(
          fontSize: 14, fontWeight: FontWeight.w600, color: headingColor,
        ),
        labelSmall: GoogleFonts.spaceMono(
          fontSize: 10, fontWeight: FontWeight.w400, color: bodyColor.withAlpha(150),
        ),
      ),

      // Page transitions — fast, easeInOut
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }

  // Convenience getters for backward compatibility
  static ThemeData get darkTheme => build(
        brightness: Brightness.dark,
        accent: AccentTheme.acidGreen,
      );
}