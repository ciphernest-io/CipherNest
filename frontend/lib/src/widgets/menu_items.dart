import 'package:flutter/material.dart';

import 'theme_icon.dart';

/// A popup-menu row with a leading icon: the one shape every three-dot menu
/// in the Files browser and Documents shares, so no menu mixes rows with
/// and without icons.
PopupMenuItem<String> iconMenuItem(
  ColorScheme cs,
  String value,
  String icon,
  String label, {
  bool danger = false,
}) {
  final color = danger ? cs.error : cs.onSurface;
  return PopupMenuItem<String>(
    value: value,
    child: Row(children: [
      ThemeIcon(icon, color: danger ? color : color.withAlpha(190), size: 20),
      const SizedBox(width: 12),
      Text(label, style: TextStyle(color: color)),
    ]),
  );
}
