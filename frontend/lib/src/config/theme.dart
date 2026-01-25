import 'package:flutter/material.dart';

class AppColors {
  static const Color background = Color(0xFF0C0F1A);
  static const Color surface = Color(0xFF151A2E);

  static const Color primary = Color(0xFF5B7CFF);
  static const Color primaryMuted = Color(0xFF3A4FA3);

  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0xFFB0B3C6);
  static const Color divider = Color(0xFF2A2E45);
}

class AppTheme {
  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'Inter',

      scaffoldBackgroundColor: AppColors.background,

      colorScheme: const ColorScheme.dark(
        primary: AppColors.primary,
        background: AppColors.background,
        surface: AppColors.surface,
      ),

      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
        headlineMedium: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
        bodyLarge: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w400,
          color: AppColors.textPrimary,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: AppColors.textSecondary,
        ),
      ),

      dividerColor: AppColors.divider,
    );
  }
}
