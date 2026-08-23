import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';
import 'theme_packs.dart';

/// How the light/dark decision is made. [system] follows the OS setting
/// live (the default for fresh installs — MTR#1 T1); [light]/[dark] pin it.
enum AppThemeMode { system, light, dark }

/// Controls the app's visual theme: a [ThemePack] (Binary, Burrow, Corporate,
/// Alien, Paper, Garnet, Hackerman) and a brightness mode (system-following /
/// light / dark). Switching the pack swaps color + fonts + radii + density
/// together — every widget that reads `Theme.of(context)` re-themes
/// automatically.
///
/// Listen via [ListenableBuilder] / [AnimatedBuilder] for live theme switches.
/// The App's [WidgetsBindingObserver.didChangePlatformBrightness] must call
/// [onPlatformBrightnessChanged] so system-mode tracks the OS live.
class ThemeController extends ChangeNotifier {
  static final ThemeController _instance = ThemeController._internal();
  factory ThemeController() => _instance;
  ThemeController._internal() {
    _load();
  }

  ThemePack _pack = ThemePack.binary;
  AppThemeMode _mode = AppThemeMode.system;
  Brightness _platformBrightness =
      PlatformDispatcher.instance.platformBrightness;

  ThemePack get pack => _pack;
  AppThemeMode get mode => _mode;

  /// The RESOLVED brightness (system mode resolves to the OS setting).
  Brightness get brightness => switch (_mode) {
        AppThemeMode.system => _platformBrightness,
        AppThemeMode.light => Brightness.light,
        AppThemeMode.dark => Brightness.dark,
      };

  ThemePackTokens get tokens => ThemePackTokens.forPackMode(_pack, brightness);

  ThemeData get themeData => AppTheme.build(pack: _pack, mode: brightness);

  void setPack(ThemePack p) {
    if (_pack == p) return;
    _pack = p;
    notifyListeners();
    _save();
  }

  void setMode(AppThemeMode m) {
    if (_mode == m) return;
    _mode = m;
    notifyListeners();
    _save();
  }

  /// Legacy convenience: pin an explicit brightness (leaves system mode).
  void setBrightness(Brightness b) =>
      setMode(b == Brightness.light ? AppThemeMode.light : AppThemeMode.dark);

  void toggleBrightness() {
    setBrightness(
      brightness == Brightness.dark ? Brightness.light : Brightness.dark,
    );
  }

  /// Cycle to the next pack in [ThemePack.values] order. Handy for a debug
  /// shake / keyboard shortcut.
  void cyclePack() {
    final values = ThemePack.values;
    final next = (values.indexOf(_pack) + 1) % values.length;
    setPack(values[next]);
  }

  /// Fed by the App's lifecycle observer so system mode re-themes the
  /// moment the OS flips (the interior used to stay dark after the icon
  /// had already followed the system).
  void onPlatformBrightnessChanged(Brightness b) {
    if (_platformBrightness == b) return;
    _platformBrightness = b;
    if (_mode == AppThemeMode.system) notifyListeners();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    // New keys (string-based, easier to debug than int indices). The legacy
    // `theme_accent` / `theme_brightness` ints from the 4-accent system are
    // ignored — clean break per the design-system migration.
    _pack = ThemePackX.fromWire(prefs.getString('theme_pack'));
    // Absent = system (fresh-install default). Legacy 'dark'/'light' values
    // written by the two-state era stay pinned — existing users keep the
    // look they chose.
    _mode = switch (prefs.getString('theme_mode')) {
      'light' => AppThemeMode.light,
      'dark' => AppThemeMode.dark,
      _ => AppThemeMode.system,
    };
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_pack', _pack.wire);
    await prefs.setString(
      'theme_mode',
      switch (_mode) {
        AppThemeMode.system => 'system',
        AppThemeMode.light => 'light',
        AppThemeMode.dark => 'dark',
      },
    );
  }
}
