import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';

import 'src/app.dart';
import 'services/cache_manager_service.dart';
import 'services/auto_sync_worker.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  CacheManagerService().enforceCacheLimit();
  runApp(const App());
}
