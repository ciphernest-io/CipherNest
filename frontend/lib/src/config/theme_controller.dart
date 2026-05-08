import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme.dart';

/// Controls the app's visual theme: brightness (dark/light) and accent color.
/// Screens and widgets listen to this via [ListenableBuilder] or
/// by wrapping the MaterialApp in a builder that reads [themeData].
class ThemeController extends ChangeNotifier {
  static final ThemeController _instance = ThemeController._internal();
  factory ThemeController() => _instance;
  ThemeController._internal() {
    _load();
  }

  Brightness _brightness = Brightness.dark;
  AccentTheme _accent = AccentTheme.acidGreen;

  Brightness get brightness => _brightness;
  AccentTheme get accent => _accent;
  AccentColors get accentColors => AccentColors.fromTheme(_accent);

  ThemeData get themeData => AppTheme.build(
        brightness: _brightness,
        accent: _accent,
      );

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

  void setAccent(AccentTheme a) {
    if (_accent == a) return;
    _accent = a;
    notifyListeners();
    _save();
  }

  void cycleAccent() {
    final values = AccentTheme.values;
    final next = (values.indexOf(_accent) + 1) % values.length;
    setAccent(values[next]);
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final brightnessIndex = prefs.getInt('theme_brightness') ?? 0;
    final accentIndex = prefs.getInt('theme_accent') ?? 0;
    _brightness = brightnessIndex == 1 ? Brightness.light : Brightness.dark;
    _accent = AccentTheme.values[accentIndex.clamp(0, AccentTheme.values.length - 1)];
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('theme_brightness', _brightness == Brightness.light ? 1 : 0);
    await prefs.setInt('theme_accent', _accent.index);
  }
}