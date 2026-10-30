import 'package:flutter/material.dart';

/// A [PopupMenuButton] whose menu opens BELOW the button, never over it, and
/// whose barrier dismisses on any pointer down outside the menu: a tap, a
/// swipe or a drag all close it. The stock menu covers the button it came
/// from and its barrier only reacts to a completed tap, so a swipe outside
/// the menu is swallowed and the menu stays open.
///
/// Drop-in: same constructor and the same [PopupMenuEntry] items. Entries
/// still pop the route with their value themselves, exactly as they do under
/// the stock button, so [onSelected] and [onCanceled] behave the same.
class CnMenuButton<T> extends PopupMenuButton<T> {
  const CnMenuButton({
    super.key,
    required super.itemBuilder,
    super.initialValue,
    super.onOpened,
    super.onSelected,
    super.onCanceled,
    super.tooltip,
    super.elevation,
    super.padding,
    super.child,
    super.splashRadius,
    super.icon,
    super.iconSize,
    super.offset,
    super.enabled,
    super.shape,
    super.color,
    super.iconColor,
    super.enableFeedback,
    super.constraints,
    super.position,
    super.style,
  });

  @override
  PopupMenuButtonState<T> createState() => _CnMenuButtonState<T>();
}

class _CnMenuButtonState<T> extends PopupMenuButtonState<T> {
  @override
  void showButtonMenu() {
    final items = widget.itemBuilder(context);
    if (items.isEmpty) return;
    final button = context.findRenderObject()! as RenderBox;
    final navigator = Navigator.of(context);
    final overlay =
        navigator.overlay!.context.findRenderObject()! as RenderBox;
    final anchor = Rect.fromPoints(
      button.localToGlobal(Offset.zero, ancestor: overlay),
      button.localToGlobal(button.size.bottomRight(Offset.zero),
          ancestor: overlay),
    ).shift(widget.offset);
    widget.onOpened?.call();
    navigator
        .push(_CnMenuRoute<T>(
      anchor: anchor,
      items: items,
      initialValue: widget.initialValue,
      elevation: widget.elevation,
      shape: widget.shape,
      color: widget.color,
      constraints: widget.constraints,
      capturedThemes:
          InheritedTheme.capture(from: context, to: navigator.context),
    ))
        .then<void>((T? value) {
      if (!mounted) return;
      if (value == null) {
        widget.onCanceled?.call();
        return;
      }
      widget.onSelected?.call(value);
    });
  }
}

const double _kScreenPadding = 8.0;
const double _kGap = 4.0;
const double _kMinWidth = 112.0;
const double _kMaxWidth = 280.0;

class _CnMenuRoute<T> extends PopupRoute<T> {
  _CnMenuRoute({
    required this.anchor,
    required this.items,
    required this.initialValue,
    required this.elevation,
    required this.shape,
    required this.color,
    required this.constraints,
    required this.capturedThemes,
  });

  final Rect anchor;
  final List<PopupMenuEntry<T>> items;
  final T? initialValue;
  final double? elevation;
  final ShapeBorder? shape;
  final Color? color;
  final BoxConstraints? constraints;
  final CapturedThemes capturedThemes;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss menu';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 160);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 100);

  /// The whole point of the class. The stock [ModalBarrier] dismisses on a
  /// completed tap only; a finger that moves past the tap slop is a swipe
  /// and gets swallowed. Here the first pointer down outside the menu closes
  /// it, whatever the finger does next.
  @override
  Widget buildModalBarrier() {
    return Semantics(
      label: barrierLabel,
      onDismiss: () {
        if (isCurrent) navigator?.pop();
      },
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) {
          if (isCurrent) navigator?.pop();
        },
        child: const SizedBox.expand(),
      ),
    );
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    final theme = Theme.of(context);
    final menuTheme = PopupMenuTheme.of(context);
    final children = <Widget>[];
    for (final item in items) {
      final selected = initialValue != null && item.represents(initialValue);
      children.add(selected
          ? ColoredBox(color: theme.highlightColor, child: item)
          : item);
    }
    final menu = Material(
      type: MaterialType.card,
      elevation: elevation ?? menuTheme.elevation ?? 3,
      shadowColor: menuTheme.shadowColor,
      surfaceTintColor: menuTheme.surfaceTintColor,
      color: color ?? menuTheme.color ?? theme.colorScheme.surfaceContainer,
      shape: shape ??
          menuTheme.shape ??
          const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(4))),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: constraints ??
            const BoxConstraints(minWidth: _kMinWidth, maxWidth: _kMaxWidth),
        child: IntrinsicWidth(
          child: SingleChildScrollView(
            padding: menuTheme.menuPadding ??
                const EdgeInsets.symmetric(vertical: 8),
            child: ListBody(children: children),
          ),
        ),
      ),
    );
    final curve =
        CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return capturedThemes.wrap(
      CustomSingleChildLayout(
        delegate: _CnMenuLayout(anchor, Directionality.of(context),
            MediaQuery.paddingOf(context)),
        child: FadeTransition(
          opacity: curve,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.92, end: 1).animate(curve),
            alignment: Alignment.topRight,
            child: menu,
          ),
        ),
      ),
    );
  }
}

/// Places the menu just under the anchor, right edges aligned, and keeps it
/// on screen: it slides left if it would overflow, and flips above the
/// anchor when there is more room there than below.
class _CnMenuLayout extends SingleChildLayoutDelegate {
  _CnMenuLayout(this.anchor, this.textDirection, this.padding);

  final Rect anchor;
  final TextDirection textDirection;
  final EdgeInsets padding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final maxH = constraints.maxHeight - padding.vertical - 2 * _kScreenPadding;
    return BoxConstraints.loose(Size(
      constraints.maxWidth - 2 * _kScreenPadding,
      maxH > 0 ? maxH : constraints.maxHeight,
    ));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final minX = _kScreenPadding + padding.left;
    final maxX = size.width - _kScreenPadding - padding.right - childSize.width;
    final minY = _kScreenPadding + padding.top;
    final maxY =
        size.height - _kScreenPadding - padding.bottom - childSize.height;

    double x = textDirection == TextDirection.rtl
        ? anchor.left
        : anchor.right - childSize.width;
    x = x.clamp(minX, maxX < minX ? minX : maxX);

    final below = anchor.bottom + _kGap;
    final roomBelow = size.height - padding.bottom - below;
    double y;
    if (childSize.height <= roomBelow ||
        roomBelow >= anchor.top - padding.top) {
      y = below;
    } else {
      y = anchor.top - _kGap - childSize.height;
    }
    y = y.clamp(minY, maxY < minY ? minY : maxY);
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_CnMenuLayout oldDelegate) =>
      anchor != oldDelegate.anchor ||
      textDirection != oldDelegate.textDirection ||
      padding != oldDelegate.padding;
}
