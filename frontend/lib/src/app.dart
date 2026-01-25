import 'package:flutter/material.dart';

import 'config/routes.dart';
import 'config/theme.dart';

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CipherNest',
      debugShowCheckedModeBanner: false,

      // Theme
      theme: AppTheme.darkTheme,

      // Initial route
      initialRoute: AppRoutes.splash,

      // Centralized routing
      onGenerateRoute: AppRoutes.generateRoute,
    );
  }
}
