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
  static const kShowToday = 'gallery_show_today';
  static const kShowOnThisDay = 'gallery_show_on_this_day';
  static const kShowLastMonth = 'gallery_show_last_month';
  static const kShowBestOf = 'gallery_show_best_of';
  static const kShowFeaturedVideo = 'gallery_show_featured_video';

  /// Every story kind under the Featured master switch, with its label.
  static const subKinds = <(String key, String label, String subtitle)>[
    (kShowYearAgo, 'Years ago', 'Photos from this day in past years'),
    (kShowOnThisDay, 'On this day', 'Same date, every year you have'),
    (kShowToday, 'Today', 'A recap of what you added today'),
    (kShowLastMonth, 'Last month', 'A look back at last month'),
    (kShowBestOf, 'Best of the month', 'Your favourites this month'),
    (kShowFeaturedVideo, 'Featured video', 'One random video'),
  ];

  Future<bool> read(String key, {bool fallback = true}) async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(key) ?? fallback;
  }

  Future<void> set(String key, bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(key, v);
    changed.value++;
  }

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
