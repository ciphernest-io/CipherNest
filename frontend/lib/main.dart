import 'package:flutter/material.dart';

import 'src/app.dart';
import 'services/cache_manager_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  CacheManagerService().enforceCacheLimit();
  runApp(const App());
}
