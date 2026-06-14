import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';
import 'theme_packs.dart';

/// Controls the app's visual theme: a [ThemePack] (Binary, Burrow, Corporate,
/// Alien, Paper, Garnet, Hackerman) and a brightness mode (dark / light).
/// Switching the pack swaps color + fonts + radii + density together — every
/// widget that reads `Theme.of(context)` re-themes automatically.
///
/// Listen via [ListenableBuilder] / [AnimatedBuilder] for live theme switches.
class ThemeController extends ChangeNotifier {
  static final ThemeController _instance = ThemeController._internal();
  factory ThemeController() => _instance;
  ThemeController._internal() {
    _load();
  }

  // Default = Binary / dark (matches the design system's `:root` default).
  ThemePack _pack = ThemePack.binary;
  Brightness _brightness = Brightness.dark;

  ThemePack get pack => _pack;
  Brightness get brightness => _brightness;
  ThemePackTokens get tokens => ThemePackTokens.forPackMode(_pack, _brightness);

  ThemeData get themeData => AppTheme.build(pack: _pack, mode: _brightness);

  void setPack(ThemePack p) {
    if (_pack == p) return;
    _pack = p;
    notifyListeners();
    _save();
  }

  void setBrightness(Brightness b) {
    if (_brightness == b) return;
    _brightness = b;
    notifyListeners();
    _save();
  }

  void toggleBrightness() {
    setBrightness(
      _brightness == Brightness.dark ? Brightness.light : Brightness.dark,
    );
  }

  /// Cycle to the next pack in [ThemePack.values] order. Handy for a debug
  /// shake / keyboard shortcut.
  void cyclePack() {
    final values = ThemePack.values;
    final next = (values.indexOf(_pack) + 1) % values.length;
    setPack(values[next]);
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    // New keys (string-based, easier to debug than int indices). The legacy
    // `theme_accent` / `theme_brightness` ints from the 4-accent system are
    // ignored — clean break per the design-system migration.
    _pack = ThemePackX.fromWire(prefs.getString('theme_pack'));
    _brightness = (prefs.getString('theme_mode') ?? 'dark') == 'light'
        ? Brightness.light
        : Brightness.dark;
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_pack', _pack.wire);
    await prefs.setString(
      'theme_mode',
      _brightness == Brightness.light ? 'light' : 'dark',
    );
  }
}
