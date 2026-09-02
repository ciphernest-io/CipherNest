import 'package:flutter/material.dart';

/// Shared Hero flight for opening/closing a photo: the shuttle is always
/// the GRID side's child (the thumbnail tile, painted synchronously from
/// the session memo). Its cover-fit inside the animating rect is what
/// produces the Samsung morph — the square cell crop opens up into the
/// photo's real aspect on the way in, and closes back to the square on
/// the way out. Using the grid child also means the flight never decodes
/// anything mid-air, so it can't flash black.
Widget photoHeroShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final gridSide = direction == HeroFlightDirection.push
      ? fromHeroContext.widget
      : toHeroContext.widget;
  return (gridSide as Hero).child;
}
