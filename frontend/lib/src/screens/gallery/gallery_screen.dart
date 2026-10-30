import 'package:flutter/material.dart';

import '../../widgets/cn_menu_button.dart';

import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';
import 'albums_tab.dart';
import 'gallery_chrome.dart';
import 'gallery_search_screen.dart';
import 'menu_tab.dart';
import 'pictures_tab.dart';
import 'stories_tab.dart';

/// OneUI-style gallery shell: no app bar, no header text. Floating chrome
/// over full-bleed content — search + overflow buttons top-left (their
/// translucent pill fades in once content scrolls under them), a
/// translucent bottom pill with the four tabs, and a back-to-top button
/// that appears while the grid is in motion. The big "Gallery" title lives
/// INSIDE the Pictures scroll view (revealed by swiping down at the top);
/// see PicturesTab.
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  int _bottomNavIndex = 0;
  final _picturesKey = GlobalKey<PicturesTabState>();
  final _albumsKey = GlobalKey<AlbumsTabState>();
  final _storiesKey = GlobalKey<StoriesTabState>();
  final _chrome = GalleryChrome();
  final _pageCtrl = PageController();

  @override
  void dispose() {
    _pageCtrl.dispose();
    _chrome.dispose();
    super.dispose();
  }

  /// Pill tap: the pages slide, the same motion a swipe produces. The
  /// pages passed on the way (Pictures to Menu crosses two) must not each
  /// take the pill for a frame, so page callbacks are ignored meanwhile.
  bool _pillDriven = false;

  void _selectTab(int index) {
    if (index == _bottomNavIndex) return;
    _applyTab(index);
    _pillDriven = true;
    _pageCtrl
        .animateToPage(
          index,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() => _pillDriven = false);
  }

  void _onPageChanged(int index) {
    if (_pillDriven) return;
    _applyTab(index);
  }

  /// Shared by the pill and by swipes landing on a page.
  void _applyTab(int index) {
    if (index == _bottomNavIndex) return;
    // Selection is modal to the Pictures tab — leaving the tab exits it,
    // so the floating bar can never act on photos that aren't visible.
    _picturesKey.currentState?.exitSelection();
    setState(() => _bottomNavIndex = index);
    // Tab content changes under the overlays: reset scroll-driven state so
    // pills are visible and back-to-top is gone, then let the now-visible
    // tab re-publish its own scrolled-under state.
    _chrome.chromeHidden.value = false;
    _chrome.showBackToTop.value = false;
    // The reveal offset belongs to the tab that produced it: a revealed
    // Albums header must not leave the next tab's buttons pulled down.
    _chrome.headerReveal.value = 0;
    _chrome.scrolledUnder.value = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      switch (_bottomNavIndex) {
        case 0:
          _picturesKey.currentState?.reportChrome();
        case 1:
          _albumsKey.currentState?.reportChrome();
        case 2:
          _storiesKey.currentState?.reportChrome();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.paddingOf(context).top;
    final safeBottom = MediaQuery.paddingOf(context).bottom;

    // Back during selection deselects instead of leaving the gallery.
    return ValueListenableBuilder<bool>(
      valueListenable: _chrome.selectionActive,
      builder: (context, selection, child) => PopScope(
        canPop: !selection,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _picturesKey.currentState?.exitSelection();
        },
        child: child!,
      ),
      child: Scaffold(
      // The bottom pill is a Positioned child of the body, so a shrinking
      // body (keyboard for "Create album") would carry it up. Nothing on
      // these tabs needs to avoid the keyboard: dialogs handle their own.
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // Tabs are pages: a horizontal swipe moves between them and the
          // pill animates the same way. Each tab is kept alive off-screen
          // so scroll position, zoom level and selection survive, exactly
          // as they did in the IndexedStack this replaced.
          Positioned.fill(
            child: ValueListenableBuilder<bool>(
              valueListenable: _chrome.swipeLocked,
              builder: (context, locked, _) => PageView(
                controller: _pageCtrl,
                physics: locked
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                onPageChanged: _onPageChanged,
                // Kept-alive pages stay in the element tree, so a photo
                // that is both a grid tile and a story cover would be two
                // heroes with one tag. Only the current page's heroes fly.
                children: [
                  HeroMode(
                    enabled: _bottomNavIndex == 0,
                    child: _KeepAlive(
                        child: PicturesTab(key: _picturesKey, chrome: _chrome)),
                  ),
                  HeroMode(
                    enabled: _bottomNavIndex == 1,
                    child: _KeepAlive(
                        child: AlbumsTab(key: _albumsKey, chrome: _chrome)),
                  ),
                  // No SafeArea wrapper: Stories manages its own top inset in
                  // its header (like Pictures/Albums) so its title lands at the
                  // same level rather than a SafeArea-shifted one.
                  HeroMode(
                    enabled: _bottomNavIndex == 2,
                    child: _KeepAlive(
                        child: StoriesTab(key: _storiesKey, chrome: _chrome)),
                  ),
                  const _KeepAlive(
                      child: SafeArea(bottom: false, child: MenuTab())),
                ],
              ),
            ),
          ),
          _topButtons(safeTop),
          _backToTop(safeBottom),
          _bottomPill(safeBottom),
        ],
      ),
      ),
    );
  }

  // ---- top-left: search + overflow, translucent pill when scrolled ----

  Widget _topButtons(double safeTop) {
    return ValueListenableBuilder<bool>(
      valueListenable: _chrome.selectionActive,
      builder: (context, selection, _) => ValueListenableBuilder<double>(
        valueListenable: _chrome.headerReveal,
        builder: (context, reveal, _) {
          // The buttons belong to the grid's top edge: revealing the title
          // box pushes them DOWN with the content; their collapsed spot is
          // their upper limit when scrolling back up.
          final top = safeTop + 6 + reveal;
          // Selection swaps the CONTENT of this same line — the count and
          // the selection actions fill it edge to edge. Same top rule, so
          // it never rides into the title box, and being an overlay it
          // never pushes the photos down.
          if (selection && _bottomNavIndex == 0) {
            return Positioned(
              top: top,
              left: 10,
              right: 10,
              child: _selectionBar(),
            );
          }
          // Each tab OWNS its top pill. It rides horizontally with its own
          // page: Pictures' pill slides out to the left as you swipe to
          // Albums, and the Albums pill slides in from the right, instead of
          // one shared pill snapping. Driven by the live PageView offset.
          final w = MediaQuery.sizeOf(context).width;
          return AnimatedBuilder(
            animation: _pageCtrl,
            builder: (context, _) {
              final page = _pageCtrl.hasClients && _pageCtrl.page != null
                  ? _pageCtrl.page!
                  : _bottomNavIndex.toDouble();
              return Stack(
                children: [
                  // Tabs 0..2 carry chrome; the Menu tab (3) has none.
                  for (var i = 0; i < 3; i++)
                    if ((i - page).abs() < 1.0)
                      Positioned(
                        top: top,
                        right: 10 + (page - i) * w,
                        child: _plainTopButtonsFor(i),
                      ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _selectionBar() {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(t.rPill),
        border: Border.all(color: cs.outline.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Exit selection',
            icon: ThemeIcon('x', color: cs.onSurface),
            onPressed: () => _picturesKey.currentState?.exitSelection(),
          ),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: _chrome.selectionCount,
              builder: (context, n, _) => Text(
                '$n selected',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Move to folder',
            icon: ThemeIcon('folder', color: cs.onSurface),
            onPressed: () =>
                _picturesKey.currentState?.moveSelectedToFolder(),
          ),
          IconButton(
            tooltip: 'Hide from views',
            icon: ThemeIcon('visibility_off', color: cs.onSurface),
            onPressed: () => _picturesKey.currentState?.hideSelected(),
          ),
          IconButton(
            tooltip: 'Share',
            icon: ThemeIcon('shareFat', color: cs.onSurface),
            onPressed: () => _picturesKey.currentState?.shareSelected(),
          ),
          IconButton(
            tooltip: 'Delete',
            icon: ThemeIcon('trash', color: cs.error),
            onPressed: () => _picturesKey.currentState?.deleteSelected(),
          ),
        ],
      ),
    );
  }

  Widget _plainTopButtonsFor(int tabIndex) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return ValueListenableBuilder<bool>(
      valueListenable: _chrome.chromeHidden,
      builder: (context, hidden, _) => ValueListenableBuilder<bool>(
        valueListenable: _chrome.scrolledUnder,
        builder: (context, under, _) {
          final visible = !hidden;
          // Pictures, Albums and Stories all have the reveal header, so the
          // pill only solidifies once their content scrolls under it. The
          // Menu tab (3) has no reveal, so it stays solid.
          final pillBg = under;
          return IgnorePointer(
            ignoring: !visible,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                padding: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh
                      .withValues(alpha: pillBg ? 0.82 : 0),
                  borderRadius: BorderRadius.circular(t.rPill),
                  border: Border.all(
                    color:
                        cs.outline.withValues(alpha: pillBg ? 0.35 : 0),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (tabIndex == 1)
                      IconButton(
                        tooltip: 'New album',
                        icon: ThemeIcon('plus', color: cs.onSurface),
                        onPressed: () =>
                            _albumsKey.currentState?.createAlbum(),
                      ),
                    IconButton(
                      tooltip: 'Search',
                      icon: ThemeIcon('magnifyingGlass',
                          color: cs.onSurface),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const GallerySearchScreen()),
                      ),
                    ),
                    // Only Pictures has overflow actions (Settings lives in
                    // the Menu tab); the other tabs get no three-dot.
                    if (tabIndex == 0) _overflowMenu(cs),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _overflowMenu(ColorScheme cs) {
    final t = ThemeController().tokens;
    return CnMenuButton<String>(
      tooltip: 'More',
      // Below the button, never over it.
      icon: ThemeIcon('dotsThreeVertical', color: cs.onSurface),
      color: cs.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.rInput)),
      onSelected: (v) {
        final pictures = _picturesKey.currentState;
        switch (v) {
          case 'select':
            pictures?.startSelection();
          case 'sync':
            pictures?.handleSync();
        }
      },
      // Favorites live on the Stories tab as their own grid, not as a
      // filter on Pictures.
      itemBuilder: (ctx) {
        return [
          if (_bottomNavIndex == 0) ...[
            const PopupMenuItem(value: 'select', child: Text('Select')),
            const PopupMenuItem(value: 'sync', child: Text('Sync now')),
          ],
        ];
      },
    );
  }

  // ---- bottom: translucent nav pill ----

  Widget _bottomPill(double safeBottom) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return Positioned(
      left: 0,
      right: 0,
      bottom: safeBottom + 12,
      child: ValueListenableBuilder<bool>(
        valueListenable: _chrome.chromeHidden,
        builder: (context, hidden, child) => IgnorePointer(
          ignoring: hidden,
          child: AnimatedSlide(
            offset: hidden ? const Offset(0, 0.4) : Offset.zero,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: hidden ? 0 : 1,
              duration: const Duration(milliseconds: 180),
              child: child,
            ),
          ),
        ),
        child: Padding(
          // OneUI width: the pill leaves 1/8 of the screen on each side.
          padding: EdgeInsets.symmetric(
              horizontal: MediaQuery.sizeOf(context).width / 12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh.withValues(alpha: 0.86),
              borderRadius: BorderRadius.circular(t.rPill),
              border:
                  Border.all(color: cs.outline.withValues(alpha: 0.35)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              children: [
                _navItem(0, 'image', 'Pictures'),
                _navItem(1, 'photo_album', 'Albums'),
                _navItem(2, 'web_stories', 'Stories'),
                _navItem(3, 'menu', 'Menu'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _navItem(int index, String icon, String label) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    final selected = _bottomNavIndex == index;
    return Expanded(
      child: InkWell(
      onTap: () => _selectTab(index),
      borderRadius: BorderRadius.circular(t.rPill),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(t.rPill),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ThemeIcon(
              icon,
              size: 20,
              selected: selected,
              color: selected
                  ? cs.primary
                  : cs.onSurface.withValues(alpha: 0.65),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected
                    ? cs.primary
                    : cs.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  // ---- back to top ----

  Widget _backToTop(double safeBottom) {
    final cs = Theme.of(context).colorScheme;
    return Positioned(
      left: 0,
      right: 0,
      // Clears the bottom pill (~64) plus a gap.
      bottom: safeBottom + 12 + 64 + 10,
      child: ValueListenableBuilder<bool>(
        valueListenable: _chrome.showBackToTop,
        builder: (context, show, child) => IgnorePointer(
          ignoring: !show || _bottomNavIndex != 0,
          child: AnimatedOpacity(
            opacity: show && _bottomNavIndex == 0 ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: child,
          ),
        ),
        child: Center(
          child: Material(
            color: cs.surfaceContainerHigh.withValues(alpha: 0.9),
            shape: CircleBorder(
              side: BorderSide(
                  color: cs.outline.withValues(alpha: 0.35)),
            ),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _picturesKey.currentState?.scrollToTop(),
              child: SizedBox(
                width: 42,
                height: 42,
                child: Center(
                  child: ThemeIcon('keyboard_arrow_up',
                      size: 24, color: cs.onSurface),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

}

/// Keeps a PageView page mounted while it is off-screen.
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});
  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
