import 'dart:developer';

/// DevTools-timeline zones for the performance baseline (see PERF.md).
///
/// These mark the statically-identified hot paths so a --profile capture
/// attributes main-isolate time to named zones instead of anonymous Dart
/// frames. dart:developer timeline events are near-zero-cost when no
/// listener is attached, so the zones ship in all build modes.
///
/// [trace] wraps ASYNC work as a TimelineTask (async events may span
/// awaits); [traceSync] wraps synchronous work (must NOT span an await —
/// sync events have to nest).
Future<T> trace<T>(String name, Future<T> Function() body) async {
  final task = TimelineTask()..start(name);
  try {
    return await body();
  } finally {
    task.finish();
  }
}

T traceSync<T>(String name, T Function() body) {
  Timeline.startSync(name);
  try {
    return body();
  } finally {
    Timeline.finishSync();
  }
}
