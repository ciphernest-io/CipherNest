import 'package:flutter/material.dart';

import '../../config/media_budget.dart';
import '../../../services/thumb_store.dart';

/// Shared Hero flight for opening/closing a photo.
///
/// The shuttle is a PLAIN image straight from the shared ThumbStore
/// provider — never the grid's stateful GalleryGridItem, which re-runs its
/// async resolve ladder when rebuilt in the flight overlay and paints a
/// blank container for its first frame (the "black photo area" seen during
/// the flight). The provider is the exact warm ImageCache entry the grid
/// tile used, so it paints synchronously and the flight never flashes.
///
/// BoxFit.cover inside the animating rect is what produces the Samsung
/// morph: the square cell crop opens into the photo's real aspect on the
/// way in and closes back on the way out.
Widget photoHeroShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  // Both heroes share the tag 'photo-<id>'; recover the id from either end.
  final tag = ((direction == HeroFlightDirection.push
          ? fromHeroContext.widget
          : toHeroContext.widget) as Hero)
      .tag;
  final id = tag is String && tag.startsWith('photo-')
      ? tag.substring(6)
      : null;
  final provider = id == null
      ? null
      : ThumbStore.instance
          .providerFor(id, width: MediaBudget.thumbDecodeWidth);
  if (provider == null) {
    // No thumbnail resolved yet: fall back to the grid child rather than
    // a blank (rare — the tile the user tapped is always resolved).
    final gridSide = direction == HeroFlightDirection.push
        ? fromHeroContext.widget
        : toHeroContext.widget;
    return (gridSide as Hero).child;
  }
  return Image(image: provider, fit: BoxFit.cover, gaplessPlayback: true);
}
