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
import 'src/utils/byte_format.dart';
import 'services/cache_manager_service.dart';
import 'services/database_service.dart';
import 'services/auto_sync_worker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Media-session + notification channel for background music playback.
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.ciphernest.vault.audio',
    androidNotificationChannelName: 'Music playback',
    androidNotificationOngoing: true,
  );
  Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  // Size-unit preference (1000 vs 1024) — cached before any UI formats.
  await ByteFormat.init();
  // Folder-lens preference — cached before any list query runs.
  await DatabaseService.initFolderLens();
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
