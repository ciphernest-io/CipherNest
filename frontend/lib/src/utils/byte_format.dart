import 'package:shared_preferences/shared_preferences.dart';

/// One byte formatter for the whole app.
///
/// Default base is 1000 (SI) — what Samsung Gallery and Android's own UI
/// use, so CipherNest's numbers agree with what users see elsewhere on the
/// phone. A Settings toggle switches to 1024 (binary) for people who want
/// KiB semantics. The base is cached statically so [formatBytes] stays
/// synchronous (formatters run inside build methods).
class ByteFormat {
  ByteFormat._();

  static const String prefKey = 'size_units_base';
  static int _base = 1000;

  static int get base => _base;

  /// Loads the persisted base. Called once from main() before runApp.
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(prefKey);
    if (saved == 1000 || saved == 1024) _base = saved!;
  }

  /// Persists and applies a new base. Callers setState afterwards so
  /// visible figures reformat immediately.
  static Future<void> setBase(int base) async {
    if (base != 1000 && base != 1024) return;
    _base = base;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(prefKey, base);
  }
}

/// "0 B" / "12 B" / "3.4 KB" / "7.23 MB" / "1.25 GB", in the active base.
/// MB gets two decimals — Samsung Gallery shows "6.32 MB", and matching it
/// digit-for-digit is the point of the 1000 default.
String formatBytes(int bytes) {
  final base = ByteFormat.base;
  if (bytes < base) return '$bytes B';
  final kb = bytes / base;
  if (kb < base) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / base;
  if (mb < base) return '${mb.toStringAsFixed(2)} MB';
  return '${(mb / base).toStringAsFixed(2)} GB';
}
