import 'package:flutter/material.dart';

import 'config/routes.dart';
import 'config/theme_controller.dart';

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  final _themeController = ThemeController();

  @override
  void initState() {
    super.initState();
    _themeController.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    _themeController.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CipherNest',
      debugShowCheckedModeBanner: false,
      theme: _themeController.themeData,
      initialRoute: AppRoutes.splash,
      onGenerateRoute: AppRoutes.generateRoute,
    );
  }
}