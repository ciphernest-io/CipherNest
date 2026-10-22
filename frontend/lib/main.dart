import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:workmanager/workmanager.dart';
// Forces every Material Symbol IconData to be reachable so the dynamic
// `SymbolsGet.get(name, style)` lookup used by ThemeIcon survives Flutter's
// icon tree-shaking. Required by the material_symbols_icons package docs.
// ignore: unused_import
import 'package:material_symbols_icons/symbols_map.dart';

import 'src/app.dart';
import 'src/config/media_budget.dart';
import 'src/config/theme_controller.dart';
import 'src/screens/splash/splash_screen.dart';
import 'src/utils/byte_format.dart';
import 'services/cache_manager_service.dart';
import 'services/auto_sync_worker.dart';
import 'services/network_timeouts.dart';
import 'services/network_timeouts.dart';

/// Decodes the splash mark into the image cache before the first frame.
/// Without this the splash paints its first frame without the logo and pops
/// it in a frame later (the "jitter" on cold start); with it the Image
/// widget finds the decoded bitmap synchronously.
Future<void> _warmSplashLogo() {
  final completer = Completer<void>();
  final view = PlatformDispatcher.instance.implicitView;
  final stream = const AssetImage(SplashScreen.logoAsset).resolve(
    ImageConfiguration(devicePixelRatio: view?.devicePixelRatio ?? 1.0),
  );
  late final ImageStreamListener listener;
  void done() {
    stream.removeListener(listener);
    if (!completer.isCompleted) completer.complete();
  }

  listener = ImageStreamListener(
    (_, _) => done(),
    onError: (_, _) => done(),
  );
  stream.addListener(listener);
  return completer.future;
}

Future<void> main() async {
  // MASVS F-12: Flutter does not strip debugPrint from release builds, and
  // the 120-odd call sites would otherwise reach logcat on every phone. One
  // override silences them all in release; debug builds keep their output.
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
  WidgetsFlutterBinding.ensureInitialized();
  CipherNestHttpOverrides.install();
  CipherNestHttpOverrides.install();
  // Everything awaited here delays the first frame (the flat pre-splash
  // surface the OS shows). Each item is a platform round-trip, so they run
  // CONCURRENTLY: the wait is the slowest one, not the sum. Awaited at all
  // because each must precede the UI: the theme + decoded mark so the
  // first frame is final (no re-theme, no re-layout), the audio session
  // before any AudioPlayer exists (just_audio_background contract), the
  // size-unit preference before any screen formats bytes.
  await Future.wait([
    // Image-cache budget BEFORE any screen decodes: the default 100 MiB
    // cache is smaller than one viewer page, and its evictions were the
    // black grid tiles on viewer close.
    MediaBudget.init(),
    ThemeController().load(),
    _warmSplashLogo(),
    JustAudioBackground.init(
      androidNotificationChannelId: 'com.ciphernest.vault.audio',
      androidNotificationChannelName: 'Music playback',
      androidNotificationOngoing: true,
      // Monochrome silhouette of the nest wordmark. The default
      // 'mipmap/ic_launcher' is a full-color icon, which Android renders as a
      // solid white box in the status bar / media notification.
      androidNotificationIcon: 'drawable/ic_stat_ciphernest',
    ),
    ByteFormat.init(),
  ]);
  Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  CacheManagerService().enforceCacheLimit();
  // Sweep file_picker's cache-copy directory on cold start. Per-attempt
  // cleanup happens in the upload flows' finally blocks; this catches
  // copies orphaned by process death mid-pick. Cold start only — calling
  // it mid-session could delete another screen's in-flight pick.
  FilePicker.platform.clearTemporaryFiles().catchError((_) => null);
  // Fire-and-forget: re-registers the auto-sync periodic task if the user
  // is on background mode. Idempotent — a no-op if the OS still has the
  // task scheduled, a re-register if it dropped it (force-stop, OEM
  // aggressive killer, plugin update).
  AutoSyncScheduler.reconcileWithPersistedMode();
  runApp(const App());
}
