import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cross-screen notifier for the two gallery view preferences: whether to
/// show the "featured" card and whether to show "a year ago" memories on
/// the Stories tab. Settings writes here; Stories subscribes.
///
/// Without this, the Settings toggles wrote SharedPreferences but nothing
/// poked the Stories tab — which lives inside an `IndexedStack` and doesn't
/// rebuild on tab-switch — so a user could toggle a section off and see it
/// still rendered until the next sync or DB mutation.
class GalleryPrefs {
  GalleryPrefs._();
  static final GalleryPrefs _instance = GalleryPrefs._();
  factory GalleryPrefs() => _instance;

  /// Bumped every time one of the tracked prefs changes. Listeners re-read
  /// the specific values they care about; keeping this a single integer
  /// notifier avoids the need for two parallel notifiers.
  final ValueNotifier<int> changed = ValueNotifier<int>(0);

  static const kShowFeatured = 'gallery_show_featured';
  static const kShowYearAgo = 'gallery_show_year_ago';

  Future<bool> readShowFeatured() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(kShowFeatured) ?? true;
  }

  Future<bool> readShowYearAgo() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(kShowYearAgo) ?? true;
  }

  Future<void> setShowFeatured(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kShowFeatured, v);
    changed.value++;
  }

  Future<void> setShowYearAgo(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kShowYearAgo, v);
    changed.value++;
  }
}
