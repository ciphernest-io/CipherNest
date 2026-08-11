import 'dart:async';
import 'package:flutter/material.dart';
import '../../widgets/theme_icon.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/routes.dart';
import '../../config/theme_controller.dart';
import '../../widgets/account_switcher.dart';
import '../../widgets/ciphernest_logo.dart';

import '../../utils/byte_format.dart';
import '../../../services/database_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/cloud/account_registry.dart';
import '../../../services/notify.dart';
import '../../../services/sync_service.dart';
import '../../../services/sync/sync_coordinator.dart';
import '../../../services/upload_pipeline.dart';
import '../../widgets/folder_picker_sheet.dart';
import '../../widgets/friendly_error_sheet.dart';
import '../folders/folder_browser_screen.dart';
import '../folders/upload_picker_session.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _isUploading = false;
  bool _isLoadingSession = true;
  Map<String, int>? _vaultStats;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initSession();
    SyncService().syncNotifier.addListener(_refreshStats);
    // Surface multi-device edit-vs-delete conflicts as they're detected.
    SyncCoordinator().conflicts.addListener(_showConflicts);
    // Any file mutation anywhere in the app (delete, upload, restore, album
    // move, edit) bumps DatabaseService's notifier — so vault usage updates
    // in place instead of only refreshing on cold start or after a full
    // sync round-trip. Also covers "user was on Settings deleting files,
    // popped back to Home, expects to see the new count immediately."
    DatabaseService().addListener(_refreshStats);
  }

  void _showConflicts() {
    final messages = SyncCoordinator().conflicts.value;
    if (messages.isEmpty) return;
    final text = messages.length == 1
        ? messages.first
        : '${messages.length} files were changed on another device. '
            'Deletions won; edits are safe in the Recycle Bin.';
    Notify.info(text);
    SyncCoordinator().clearConflicts();
  }

  @override
  void dispose() {
    SyncService().syncNotifier.removeListener(_refreshStats);
    SyncCoordinator().conflicts.removeListener(_showConflicts);
    DatabaseService().removeListener(_refreshStats);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Immediate local recompute — SQLite is fast, don't make the user
      // wait for the cloud sync round-trip. syncNow's completion will
      // bump the numbers again if the cloud state moved.
      _refreshStats();
      SyncService().syncNow();
    }
  }

  Future<void> _refreshStats() async {
    final stats = await DatabaseService().getStorageStats();
    if (mounted) setState(() => _vaultStats = stats);
  }

  Future<void> _markSetupCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('setup_completed_v1', true);
  }

  Future<void> _initSession() async {
    setState(() => _isLoadingSession = true);

    // Reaching Home is the point at which "the user has finished setup at
    // least once" — this is the flag the splash gate reads next time to
    // distinguish "signed out, restore" from "closed mid-signup, onboard
    // again." Set idempotently on every home mount.
    unawaited(_markSetupCompleted());

    try {
      final active = AccountRegistry().activeAccount;
      String? email = active?.email;
      email ??= await CloudService().restoreSession();

      if (!mounted) return;
      if (active != null) {
        DatabaseService().setCurrentAccount(active.id);
        setState(() => _isLoadingSession = false);
        _refreshStats();
        SyncService().syncNow();
      } else if (email != null) {
        // Legacy edge case: no active account but a session exists.
        setState(() => _isLoadingSession = false);
        _refreshStats();
        SyncService().syncNow();
      } else {
        // Splash + login should have caught this and routed to reconnect,
        // but we defend against race conditions (token invalidated after
        // login success). Route rather than render an inline error.
        Navigator.pushReplacementNamed(context, AppRoutes.reconnect);
      }
    } catch (e, s) {
      debugPrint('Home _initSession failed: $e\n$s');
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, AppRoutes.reconnect);
    }
  }

  /// Pick-then-place (pCloud pattern): unrestricted multi-pick, then the
  /// Files browser opens in PICKER MODE — navigate anywhere, create folders
  /// mid-flow, "Upload here". The pipeline classifies types by extension.
  Future<void> _handleUpload() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: false,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    if (!mounted) return;

    final dest = await _pickDestination(result.files,
        label: result.files.length == 1
            ? result.files.first.name
            : '${result.files.length} files');
    if (dest == null) return; // cancelled

    await _uploadPicked(result.files,
        category: UploadCategory.other, folderId: dest.folderId);
  }

  /// Pushes the browser in picker mode and awaits the session. Null =
  /// cancelled (footer Cancel OR backing all the way out — the fallback
  /// completion below makes even a missed route name degrade to cancel).
  Future<FolderPickResult?> _pickDestination(List<PlatformFile> files,
      {required String label}) async {
    final session = UploadPickerSession(files: files, label: label);
    await Navigator.of(context).push(MaterialPageRoute(
      settings: const RouteSettings(name: kUploadPickerRouteName),
      builder: (_) => FolderBrowserScreen(pickerSession: session),
    ));
    if (!session.destination.isCompleted) {
      session.destination.complete(null);
    }
    return session.destination.future;
  }

  Future<void> _uploadPicked(
    List<PlatformFile> files, {
    required UploadCategory category,
    String? folderId,
  }) async {
    setState(() => _isUploading = true);
    try {
      // Progress + the batch summary live in the activity pill
      // (uploadBatch registers the task).
      final outcomes = await UploadPipeline.uploadBatch(
        files,
        category: category,
        folderId: folderId,
      );
      if (mounted) await _reportUploadOutcomes(outcomes);
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  /// Summary + progress ride the activity pill; only a failure's DETAIL
  /// still needs this screen (the actionable error sheet).
  Future<void> _reportUploadOutcomes(List<UploadOutcome> outcomes) async {
    final failures = outcomes.where((o) => !o.ok).toList();
    if (failures.isNotEmpty && mounted) {
      await showCnestError(
          context, UploadPipeline.mapUploadError(failures.first.error!));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_isLoadingSession) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // Missing-cloud state is now handled by the reconnect screen (routed to
    // from splash, login, or _initSession's defensive catch). Home does not
    // render an inline error surface anymore.

    final cards = <Widget>[
      _DashboardCard(
        title: 'Photos & Videos',
        icon: 'images',
        color: cs.primary,
        showCardArt: true,
        onTap: () async {
          await Navigator.pushNamed(context, AppRoutes.gallery);
        },
      ),
      _DashboardCard(
        title: 'Folders',
        icon: 'folderOpen',
        color: cs.primary,
        onTap: () => Navigator.pushNamed(context, AppRoutes.folders),
      ),
      _DashboardCard(
        title: 'Documents',
        icon: 'fileText',
        color: cs.primary,
        onTap: () => Navigator.pushNamed(context, AppRoutes.documents),
      ),
      _DashboardCard(
        title: 'Music',
        icon: 'musicNote',
        color: cs.primary,
        onTap: () => Navigator.pushNamed(context, AppRoutes.audio),
      ),
      _DashboardCard(
        title: 'Other Files',
        // Archive box, not a folder — 'folder' collided with the Folders
        // card one row up.
        icon: 'archiveBox',
        color: cs.primary,
        onTap: () => Navigator.pushNamed(context, AppRoutes.otherFiles),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const CiphernestLogo(fontSize: 22),
        actions: [
          const AccountSwitcher(),
          IconButton(
            icon: ThemeIcon('gear'),
            onPressed: () => Navigator.pushNamed(context, AppRoutes.settings),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your Vault', style: Theme.of(context).textTheme.headlineMedium),
            ListenableBuilder(
              listenable: AccountRegistry(),
              builder: (context, _) {
                final active = AccountRegistry().activeAccount;
                if (active == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Text(
                    '${active.email} · ${active.providerName}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurface.withAlpha(120)),
                  ),
                );
              },
            ),
            const SizedBox(height: 20),
            _VaultUsageCard(stats: _vaultStats),
            const SizedBox(height: 16),
            // Landscape: pack the category cards into a two-column grid so
            // the user doesn't have to scroll past their full vertical stack
            // on a short canvas. Both layouts render the WHOLE list — never
            // index cards by hand (a prepend once silently dropped the last
            // card for weeks).
            OrientationBuilder(
              builder: (context, orientation) {
                if (orientation == Orientation.landscape) {
                  return Column(
                    children: [
                      for (var i = 0; i < cards.length; i += 2) ...[
                        if (i > 0) const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(child: cards[i]),
                            const SizedBox(width: 16),
                            Expanded(
                              child: i + 1 < cards.length
                                  ? cards[i + 1]
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ),
                      ],
                    ],
                  );
                }
                return Column(
                  children: [
                    for (var i = 0; i < cards.length; i++) ...[
                      if (i > 0) const SizedBox(height: 16),
                      cards[i],
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
      // Counted progress lives in the activity pill; the FAB just shows
      // busy + disabled while a batch runs.
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isUploading ? null : () => _showUploadSheet(context),
        backgroundColor: cs.primary,
        icon: _isUploading
          ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: cs.onPrimary, strokeWidth: 2))
          : ThemeIcon('plus', color: cs.onPrimary),
        label: Text(_isUploading ? 'Encrypting...' : 'Add File'),
      ),
    );
  }

  /// pCloud-style Add sheet: capture rows + ONE unrestricted upload row.
  /// The destination is chosen AFTER the pick, in the browser's picker
  /// mode ("pick then place").
  void _showUploadSheet(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: ThemeIcon('uploadSimple', color: cs.primary),
              title: Text('Upload files',
                  style: TextStyle(color: cs.onSurface)),
              subtitle: Text('Photos, documents, music, anything — then '
                  'choose the folder',
                  style: TextStyle(
                      color: cs.onSurface.withAlpha(140), fontSize: 11)),
              onTap: () {
                Navigator.pop(ctx);
                _handleUpload();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _DashboardCard extends StatelessWidget {
  final String title;
  final String icon;
  final Color color;
  final VoidCallback onTap;
  /// If true, render the active theme pack's `cardArtAsset` behind the card
  /// content. Reserved for the Photos & Videos tile per the design system.
  final bool showCardArt;

  const _DashboardCard({
    required this.title,
    required this.icon,
    required this.color,
    required this.onTap,
    this.showCardArt = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = ThemeController().tokens;
    final radius = BorderRadius.circular(tokens.rCard);

    final foreground = Row(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(tokens.rIc),
          ),
          child: ThemeIcon(icon, color: color, size: 28),
        ),
        const SizedBox(width: 16),
        Text(title, style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600, fontSize: 18)),
        const Spacer(),
        ThemeIcon('caretRight', size: 16, color: cs.onSurface.withAlpha(120)),
      ],
    );

    return InkWell(
      onTap: onTap,
      borderRadius: radius,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: radius,
          border: Border.all(color: cs.outline),
        ),
        child: showCardArt
            ? Stack(
                children: [
                  // Theme pack's signature card art (binary digits, soil,
                  // skyline, UFO, newsprint, marble, code rain) tinted into
                  // the card surface at a low alpha so the icon + label stay
                  // readable.
                  Positioned.fill(
                    child: Opacity(
                      opacity: 0.22,
                      child: Image.asset(
                        tokens.cardArtAsset,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.all(tokens.pad),
                    child: foreground,
                  ),
                ],
              )
            : Padding(
                padding: EdgeInsets.all(tokens.pad),
                child: foreground,
              ),
      ),
    );
  }
}

class _VaultUsageCard extends StatelessWidget {
  final Map<String, int>? stats;
  const _VaultUsageCard({required this.stats});

  String _fmt(int bytes) => formatBytes(bytes);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final images = stats?['images'] ?? 0;
    final docs = stats?['docs'] ?? 0;
    final audio = stats?['audio'] ?? 0;
    final other = stats?['other'] ?? 0;
    final trashBytes = stats?['trash_bytes'] ?? 0;
    final trashCount = stats?['trash_count'] ?? 0;
    // Live (non-trash) usage plus trash — the honest number for what's
    // actually costing the user's cloud quota right now. The Recycle Bin
    // sweeper doesn't touch Drive until the 30-day TTL, so a "just deleted
    // 6 MB" file is still on the wire.
    final live = images + docs + audio + other;
    final total = live + trashBytes;
    final count = stats?['total_count'] ?? 0;

    final tokens = ThemeController().tokens;
    final segments = <_UsageSegment>[
      _UsageSegment('Photos & Videos', images, cs.primary),
      _UsageSegment('Documents', docs, tokens.warning),
      _UsageSegment('Audio', audio, tokens.info),
      _UsageSegment('Other', other, tokens.fgMuted),
      if (trashBytes > 0)
        _UsageSegment('Recycle Bin', trashBytes, cs.onSurface.withAlpha(90)),
    ].where((s) => s.bytes > 0).toList();

    return Container(
      padding: EdgeInsets.all(tokens.pad),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(tokens.rCard),
        border: Border.all(color: cs.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ThemeIcon(
                'cloudCheck',
                color: cs.primary,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Vault usage',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                ),
              ),
              Text(
                stats == null ? '—' : _fmt(total),
                style: TextStyle(
                  color: cs.onSurface,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            stats == null
                ? 'Loading…'
                : trashCount > 0
                    ? '$count file${count == 1 ? '' : 's'} · '
                        '$trashCount in Recycle Bin'
                    : '$count file${count == 1 ? '' : 's'} encrypted on this account',
            style: TextStyle(
              color: cs.onSurface.withAlpha(140),
              fontSize: 12,
            ),
          ),
          if (segments.isNotEmpty) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 6,
                child: Row(
                  children: segments
                      .map(
                        (s) => Expanded(
                          flex: s.bytes,
                          child: Container(color: s.color),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: segments.map((s) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: s.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${s.label} · ${_fmt(s.bytes)}',
                      style: TextStyle(
                        color: cs.onSurface.withAlpha(180),
                        fontSize: 11,
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _UsageSegment {
  final String label;
  final int bytes;
  final Color color;
  _UsageSegment(this.label, this.bytes, this.color);
}
