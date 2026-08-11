/// Runs [op] over [items] one at a time, try/catching each, and returns the
/// REAL success count. Bulk loops must never report the requested count as
/// the success count — a partial failure that reads as full success is how
/// files quietly go missing.
Future<int> honestCount<T>(
  Iterable<T> items,
  Future<void> Function(T item) op, {
  void Function(int done)? onEach,
}) async {
  var ok = 0;
  var done = 0;
  for (final item in items) {
    try {
      await op(item);
      ok++;
    } catch (_) {
      // Counted, not rethrown — the caller's summary reports failures.
    }
    done++;
    onEach?.call(done);
  }
  return ok;
}
