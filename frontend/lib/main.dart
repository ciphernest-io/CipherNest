import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';
// Forces every Material Symbol IconData to be reachable so the dynamic
// `SymbolsGet.get(name, style)` lookup used by ThemeIcon survives Flutter's
// icon tree-shaking. Required by the material_symbols_icons package docs.
// ignore: unused_import
import 'package:material_symbols_icons/symbols_map.dart';

import 'src/app.dart';
import 'services/cache_manager_service.dart';
import 'services/auto_sync_worker.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  CacheManagerService().enforceCacheLimit();
  runApp(const App());
}
