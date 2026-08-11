/// The live channel between the background auto-sync worker isolate and the
/// UI isolate's ActivityCenter. Pure protocol — no widget imports, safe for
/// both isolates.
///
/// Messages ride an IsolateNameServer SendPort as `List<int>` (primitives
/// only cross isolates cleanly). A terminal summary is ALSO stamped into
/// SharedPreferences so a run that finishes while the app is dead still
/// surfaces as "N photos secured while you were away" on the next open.
library;

const String kBgSyncPortName = 'ciphernest.bg_sync.progress';
const String kBgSyncSummaryPref = 'bg_sync_summary_v1';

class BgSyncMessage {
  static const int typeStarted = 0;
  static const int typeScanning = 1;
  static const int typeProgress = 2;
  static const int typeTerminal = 3;

  final int type;
  final int a;
  final int b;
  const BgSyncMessage._(this.type, this.a, this.b);

  static List<int> started() => const [typeStarted];
  static List<int> scanning() => const [typeScanning];
  static List<int> progress(int done, int total) =>
      [typeProgress, done, total];
  static List<int> terminal(int synced, int failed) =>
      [typeTerminal, synced, failed];

  /// Null on anything malformed — a version-skewed worker must never crash
  /// the UI isolate's listener.
  static BgSyncMessage? decode(Object? raw) {
    if (raw is! List) return null;
    if (raw.isEmpty || raw.first is! int) return null;
    final type = raw.first as int;
    switch (type) {
      case typeStarted:
      case typeScanning:
        return BgSyncMessage._(type, 0, 0);
      case typeProgress:
      case typeTerminal:
        if (raw.length < 3 || raw[1] is! int || raw[2] is! int) return null;
        return BgSyncMessage._(type, raw[1] as int, raw[2] as int);
      default:
        return null;
    }
  }
}

String encodeBgSummary(int synced, int failed, int epochMs) =>
    '$synced|$failed|$epochMs';

({int synced, int failed, int epochMs})? decodeBgSummary(String raw) {
  final parts = raw.split('|');
  if (parts.length != 3) return null;
  final synced = int.tryParse(parts[0]);
  final failed = int.tryParse(parts[1]);
  final epochMs = int.tryParse(parts[2]);
  if (synced == null || failed == null || epochMs == null) return null;
  return (synced: synced, failed: failed, epochMs: epochMs);
}
