import 'package:flutter/material.dart';

/// The app's one route transition: the new page slides in from the right
/// OVER a page that does not move, and slides back out the same way on
/// pop while the page beneath stays exactly where it was.
///
/// Cupertino's builder also shifted the page underneath by a third of the
/// width and dimmed it, which read as the old screen drifting. Material's
/// zoom builder scales. Neither is what a stack of cards does.
class SlideOverPageTransitionsBuilder extends PageTransitionsBuilder {
  const SlideOverPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // secondaryAnimation is deliberately unused: it is what would move the
    // page underneath when another route is pushed on top of it.
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(curved),
      child: child,
    );
  }
}
