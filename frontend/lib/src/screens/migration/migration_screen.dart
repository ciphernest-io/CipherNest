import 'dart:typed_data';
import '../../utils/byte_format.dart';
import 'package:flutter/material.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../config/routes.dart';

import '../../../services/activity_center.dart';
import '../../../services/migration_service.dart';
import '../../../services/notify.dart';

enum _MigrationPhase { choosing, selectingAlbums, scanning, ready, migrating, paused, complete }

class MigrationScreen extends StatefulWidget {
  const MigrationScreen({super.key});

  @override
  State<MigrationScreen> createState() => _MigrationScreenState();
}

class _MigrationScreenState extends State<MigrationScreen> {
  _MigrationPhase _phase = _MigrationPhase.choosing;

  // Album selection
  List<AlbumInfo> _allAlbums = [];
  final Set<int> _selectedAlbumIndices = {};

  // Scan results
  List<AssetEntity> _assets = [];
  int _totalBytes = 0;

  // Progress
  MigrationProgress? _progress;
  MigrationResult? _result;

  // --- Actions ---

  Future<void> _scanFullGallery() async {
    setState(() => _phase = _MigrationPhase.scanning);
    final scan = await MigrationService().scanGallery();
    if (mounted) {
      setState(() {
        _assets = scan.assets;
        _totalBytes = scan.totalBytes;
        _phase = _MigrationPhase.ready;
      });
    }
  }

  Future<void> _showAlbumPicker() async {
    setState(() => _phase = _MigrationPhase.scanning);
    final albums = await MigrationService().getAlbums();
    if (mounted) {
      setState(() {
        _allAlbums = albums;
        _selectedAlbumIndices.clear();
        _phase = _MigrationPhase.selectingAlbums;
      });
    }
  }

  Future<void> _scanSelectedAlbums() async {
    final selectedPaths = _selectedAlbumIndices
        .map((i) => _allAlbums[i].path)
        .toList();
    if (selectedPaths.isEmpty) return;

    setState(() => _phase = _MigrationPhase.scanning);
    final scan = await MigrationService().scanGallery(albumPaths: selectedPaths);
    if (mounted) {
      setState(() {
        _assets = scan.assets;
        _totalBytes = scan.totalBytes;
        _phase = _MigrationPhase.ready;
      });
    }
  }

  Future<void> _pickManualPhotos() async {
    // Use photo_manager to get all assets, then let user multi-select
    setState(() => _phase = _MigrationPhase.scanning);
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth) {
      Notify.error('Media permissions required');
      if (mounted) setState(() => _phase = _MigrationPhase.choosing);
      return;
    }

    // Get all albums, collect all assets for a picker
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
      ),
    );

    final allAssets = <AssetEntity>[];
    final seenIds = <String>{};
    for (final album in albums) {
      final count = await album.assetCountAsync;
      if (count == 0) continue;
      final assets = await album.getAssetListRange(start: 0, end: count);
      for (final a in assets) {
        if (seenIds.add(a.id)) allAssets.add(a);
      }
    }

    if (!mounted) return;

    final selected = await Navigator.push<List<AssetEntity>>(
      context,
      MaterialPageRoute(
        builder: (_) => _AssetPickerScreen(assets: allAssets),
      ),
    );

    if (selected == null || selected.isEmpty) {
      if (mounted) setState(() => _phase = _MigrationPhase.choosing);
      return;
    }

    setState(() => _phase = _MigrationPhase.scanning);
    final scan = await MigrationService().scanGallery(manualAssets: selected);
    if (mounted) {
      setState(() {
        _assets = scan.assets;
        _totalBytes = scan.totalBytes;
        _phase = _MigrationPhase.ready;
      });
    }
  }

  Future<void> _startMigration() async {
    setState(() => _phase = _MigrationPhase.migrating);

    // Activity-center task: migration survives leaving this screen, and
    // the expanded sheet's pause/resume/cancel drive BOTH the service and
    // (when still mounted) this screen's phase, so the two surfaces agree.
    final task = ActivityCenter().start(
      kind: ActivityKind.migration,
      label: 'Migrating…',
      total: _assets.length,
      onPause: () {
        MigrationService().pause();
        if (mounted) setState(() => _phase = _MigrationPhase.paused);
      },
      onResume: () {
        MigrationService().resume();
        if (mounted) setState(() => _phase = _MigrationPhase.migrating);
      },
      onCancel: MigrationService().cancel,
    );
    _task = task;

    try {
      final result = await MigrationService().runMigration(
        assets: _assets,
        onProgress: (progress) {
          task.update(progress.current,
              total: progress.total,
              label: 'Migrating ${progress.current}/${progress.total}',
              detail: progress.currentFileName);
          if (mounted) setState(() => _progress = progress);
        },
      );
      final summary = result.failed > 0
          ? '${result.synced} migrated · ${result.failed} failed'
          : '${result.synced} photo${result.synced == 1 ? '' : 's'} migrated';
      result.failed > 0 ? task.fail(summary) : task.complete(summary);
      if (mounted) {
        setState(() {
          _result = result;
          _phase = _MigrationPhase.complete;
        });
      }
    } catch (e) {
      // Most common: cloud reconnect needed. The task terminal is the
      // surface (pill flash + sheet history); drop back to the choosing
      // phase so the user can bail cleanly.
      task.fail(e.toString().replaceFirst('Bad state: ', ''));
      if (!mounted) return;
      setState(() => _phase = _MigrationPhase.choosing);
    } finally {
      _task = null;
    }
  }

  ActivityTask? _task;

  void _pause() {
    MigrationService().pause();
    _task?.setPaused(true);
    setState(() => _phase = _MigrationPhase.paused);
  }

  void _resume() {
    MigrationService().resume();
    _task?.setPaused(false);
    setState(() => _phase = _MigrationPhase.migrating);
  }

  void _cancel() {
    MigrationService().cancel();
  }

  String _formatBytes(int bytes) => formatBytes(bytes);

  String _formatDuration(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    return '${d.inSeconds}s';
  }

  // --- Build ---

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _phase != _MigrationPhase.migrating,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _phase == _MigrationPhase.migrating) {
          _showExitConfirmation();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Import from Gallery'),
          automaticallyImplyLeading: _phase != _MigrationPhase.migrating,
          leading: _phase == _MigrationPhase.selectingAlbums ||
                  _phase == _MigrationPhase.ready
              ? IconButton(
                  icon: ThemeIcon('arrowLeft'),
                  onPressed: () => setState(() => _phase = _MigrationPhase.choosing),
                )
              : null,
        ),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _MigrationPhase.choosing:
        return _buildChoosing();
      case _MigrationPhase.selectingAlbums:
        return _buildAlbumSelector();
      case _MigrationPhase.scanning:
        return _buildScanning();
      case _MigrationPhase.ready:
        return _buildReady();
      case _MigrationPhase.migrating:
      case _MigrationPhase.paused:
        return _buildMigrating();
      case _MigrationPhase.complete:
        return _buildComplete();
    }
  }

  // --- PHASE: Choosing migration mode ---
  Widget _buildChoosing() {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        ThemeIcon('images', color: cs.primary, size: 48),
        const SizedBox(height: 16),
        Text(
          'Import Your Gallery',
          style: TextStyle(color: cs.onSurface, fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'Encrypt photos and videos from this phone into your vault. '
          'Files already in your vault are skipped automatically.',
          style: TextStyle(color: cs.onSurface.withAlpha(120), fontSize: 14),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(t.rInput),
            border: Border.all(color: cs.outline.withAlpha(60)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ThemeIcon('cloudArrowUp', color: cs.primary, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Importing directly from Google Drive or OneDrive '
                  '(existing unencrypted photos already in the cloud) '
                  'is coming in v2. For now, pull them to your device first '
                  'and use one of the options below.',
                  style: TextStyle(
                    color: cs.onSurface.withAlpha(160),
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _MigrationOption(
          icon: 'infinity',
          title: 'Entire Gallery',
          subtitle: 'Encrypt all photos and videos on this device',
          onTap: _scanFullGallery,
        ),
        const SizedBox(height: 12),
        _MigrationOption(
          icon: 'folderSimple',
          title: 'Select Albums',
          subtitle: 'Choose specific albums to migrate',
          onTap: _showAlbumPicker,
        ),
        const SizedBox(height: 12),
        _MigrationOption(
          icon: 'handTap',
          title: 'Pick Photos Manually',
          subtitle: 'Hand-pick individual photos and videos',
          onTap: _pickManualPhotos,
        ),
      ],
    );
  }

  // --- PHASE: Album selector ---
  Widget _buildAlbumSelector() {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Select Albums',
          style: TextStyle(color: cs.onSurface, fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          '${_selectedAlbumIndices.length} album${_selectedAlbumIndices.length == 1 ? '' : 's'} selected',
          style: TextStyle(color: cs.onSurface.withAlpha(120), fontSize: 14),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: ListView.builder(
            itemCount: _allAlbums.length,
            itemBuilder: (context, index) {
              final album = _allAlbums[index];
              final selected = _selectedAlbumIndices.contains(index);
              return CheckboxListTile(
                value: selected,
                activeColor: cs.primary,
                checkColor: cs.onPrimary,
                title: Text(album.name, style: TextStyle(color: cs.onSurface)),
                subtitle: Text(
                  '${album.count} item${album.count == 1 ? '' : 's'}',
                  style: TextStyle(color: cs.onSurface.withAlpha(120)),
                ),
                secondary: ThemeIcon('folderSimple', color: cs.onSurface.withAlpha(120)),
                onChanged: (val) {
                  setState(() {
                    if (val == true) {
                      _selectedAlbumIndices.add(index);
                    } else {
                      _selectedAlbumIndices.remove(index);
                    }
                  });
                },
              );
            },
          ),
        ),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: _selectedAlbumIndices.isEmpty ? null : _scanSelectedAlbums,
            style: ElevatedButton.styleFrom(
              backgroundColor: cs.primary,
              foregroundColor: cs.onPrimary,
              disabledBackgroundColor: cs.surfaceContainerHighest,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.rCard)),
            ),
            child: Text('Scan ${_selectedAlbumIndices.length} Album${_selectedAlbumIndices.length == 1 ? '' : 's'}'),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  // --- PHASE: Scanning gallery ---
  Widget _buildScanning() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 24),
          Text('Scanning your gallery...', style: TextStyle(color: cs.onSurface, fontSize: 18)),
          const SizedBox(height: 8),
          Text('This may take a moment for large libraries', style: TextStyle(color: cs.onSurface.withAlpha(120), fontSize: 14)),
        ],
      ),
    );
  }

  // --- PHASE: Ready to migrate ---
  Widget _buildReady() {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;

    if (_assets.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ThemeIcon('checkCircle', selected: true, color: t.success, size: 64),
            const SizedBox(height: 16),
            Text('All caught up!',
                style: TextStyle(color: cs.onSurface, fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('All selected photos are already in CipherNest.',
                style: TextStyle(color: cs.onSurface.withAlpha(120), fontSize: 14), textAlign: TextAlign.center),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(backgroundColor: cs.primary, foregroundColor: cs.onPrimary),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    }

    final photoCount = _assets.where((a) => a.type == AssetType.image).length;
    final videoCount = _assets.where((a) => a.type == AssetType.video).length;
    final estimatedSeconds = (photoCount * 2) + (videoCount * 8);
    final estimatedDuration = Duration(seconds: estimatedSeconds);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Text('Ready to Migrate',
            style: TextStyle(color: cs.onSurface, fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('Encrypt and upload the selected media to CipherNest.',
            style: TextStyle(color: cs.onSurface.withAlpha(120), fontSize: 14)),
        const SizedBox(height: 32),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(t.rCard),
            border: Border.all(color: cs.outline),
          ),
          child: Column(
            children: [
              _StatRow(label: 'Photos', value: '$photoCount', icon: 'image'),
              if (videoCount > 0)
                _StatRow(label: 'Videos', value: '$videoCount', icon: 'videoCamera'),
              _StatRow(label: 'Total Size', value: _formatBytes(_totalBytes), icon: 'hardDrive'),
              _StatRow(label: 'Estimated Time', value: '~${_formatDuration(estimatedDuration)}', icon: 'timer'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text('You can pause or cancel at any time. Already-uploaded files will not be affected.',
            style: TextStyle(color: cs.onSurface.withAlpha(120), fontSize: 12)),
        const Spacer(),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton.icon(
            onPressed: _startMigration,
            icon: ThemeIcon('lock', color: cs.onPrimary),
            label: const Text('Start Migration', style: TextStyle(fontSize: 16)),
            style: ElevatedButton.styleFrom(
              backgroundColor: cs.primary,
              foregroundColor: cs.onPrimary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.rCard)),
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  // --- PHASE: Migrating (and Paused) ---
  Widget _buildMigrating() {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    final p = _progress;
    final fraction = p != null && p.total > 0 ? p.current / p.total : 0.0;
    final percent = (fraction * 100).toStringAsFixed(0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Text(
          _phase == _MigrationPhase.paused ? 'Paused' : 'Migrating...',
          style: TextStyle(color: cs.onSurface, fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        if (p != null)
          Text('Encrypting: ${p.currentFileName}',
              style: TextStyle(color: cs.onSurface.withAlpha(120), fontSize: 13),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 32),
        Center(
          child: SizedBox(
            width: 160, height: 160,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 160, height: 160,
                  child: CircularProgressIndicator(
                    value: fraction, strokeWidth: 8,
                    backgroundColor: cs.outline,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      _phase == _MigrationPhase.paused ? t.warning : cs.primary,
                    ),
                  ),
                ),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('$percent%',
                        style: TextStyle(color: cs.onSurface, fontSize: 36, fontWeight: FontWeight.bold)),
                    if (p != null)
                      Text('${p.current} / ${p.total}', style: TextStyle(color: cs.onSurface.withAlpha(120), fontSize: 14)),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 32),
        if (p != null)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(t.rInput),
              border: Border.all(color: cs.outline),
            ),
            child: Column(
              children: [
                _StatRow(label: 'Secured', value: '${p.synced}', icon: 'checkCircle', iconSelected: true, color: t.success),
                if (p.failed > 0)
                  _StatRow(label: 'Failed', value: '${p.failed}', icon: 'warning', iconSelected: true, color: t.danger),
                _StatRow(label: 'Uploaded', value: _formatBytes(p.bytesUploaded), icon: 'cloudArrowUp'),
                _StatRow(label: 'ETA', value: _formatDuration(p.eta), icon: 'timer'),
              ],
            ),
          ),
        const Spacer(),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _cancel,
                style: OutlinedButton.styleFrom(
                  foregroundColor: t.danger,
                  side: BorderSide(color: t.danger),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: ElevatedButton(
                onPressed: _phase == _MigrationPhase.paused ? _resume : _pause,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _phase == _MigrationPhase.paused ? cs.primary : t.warning,
                  foregroundColor: cs.onPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(_phase == _MigrationPhase.paused ? 'Resume' : 'Pause'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  // --- PHASE: Complete ---
  Widget _buildComplete() {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    final r = _result;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ThemeIcon(
            r != null && r.failed == 0 ? 'checkCircle' : 'info',
            selected: r != null && r.failed == 0,
            color: r != null && r.failed == 0 ? t.success : t.warning,
            size: 72,
          ),
          const SizedBox(height: 20),
          Text(
            r != null && r.failed == 0 ? 'Migration Complete' : 'Migration Finished',
            style: TextStyle(color: cs.onSurface, fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          if (r != null)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(t.rCard),
                border: Border.all(color: cs.outline),
              ),
              child: Column(
                children: [
                  _StatRow(label: 'Secured', value: '${r.synced}', icon: 'checkCircle', iconSelected: true, color: t.success),
                  if (r.failed > 0)
                    _StatRow(label: 'Failed', value: '${r.failed}', icon: 'warning', iconSelected: true, color: t.danger),
                  if (r.skipped > 0)
                    _StatRow(label: 'Skipped', value: '${r.skipped}', icon: 'skipForward', color: t.fgMuted),
                ],
              ),
            ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pushNamedAndRemoveUntil(context, AppRoutes.home, (route) => false),
              style: ElevatedButton.styleFrom(
                backgroundColor: cs.primary,
                foregroundColor: cs.onPrimary,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('Go to Gallery', style: TextStyle(fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showExitConfirmation() async {
    final t = ThemeController().tokens;
    final shouldLeave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel Migration?'),
        content: const Text(
          'Files already uploaded will remain secured. '
          'You can resume migration later from Settings.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Continue')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Cancel', style: TextStyle(color: t.danger)),
          ),
        ],
      ),
    );
    if (shouldLeave == true) {
      _cancel();
      if (mounted) Navigator.pop(context);
    }
  }
}

// --- Reusable option card for the choosing phase ---
class _MigrationOption extends StatelessWidget {
  final String icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _MigrationOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(t.rCard),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(t.rCard),
          border: Border.all(color: cs.outline),
        ),
        child: Row(
          children: [
            ThemeIcon(icon, color: cs.primary, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w600, fontSize: 16)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(color: cs.onSurface.withAlpha(120), fontSize: 13)),
                ],
              ),
            ),
            ThemeIcon('caretRight', size: 16, color: cs.onSurface.withAlpha(120)),
          ],
        ),
      ),
    );
  }
}

// --- Manual photo picker screen ---
class _AssetPickerScreen extends StatefulWidget {
  final List<AssetEntity> assets;
  const _AssetPickerScreen({required this.assets});

  @override
  State<_AssetPickerScreen> createState() => _AssetPickerScreenState();
}

class _AssetPickerScreenState extends State<_AssetPickerScreen> {
  final Set<int> _selected = {};

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return Scaffold(
      appBar: AppBar(
        title: Text('${_selected.length} selected'),
        actions: [
          TextButton(
            onPressed: _selected.isEmpty
                ? null
                : () {
                    final picked = _selected.map((i) => widget.assets[i]).toList();
                    Navigator.pop(context, picked);
                  },
            child: Text(
              'Done',
              style: TextStyle(
                color: _selected.isEmpty ? cs.onSurface.withAlpha(120) : cs.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(2),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 2,
          crossAxisSpacing: 2,
        ),
        itemCount: widget.assets.length,
        itemBuilder: (context, index) {
          final asset = widget.assets[index];
          final isSelected = _selected.contains(index);

          return GestureDetector(
            onTap: () {
              setState(() {
                if (isSelected) {
                  _selected.remove(index);
                } else {
                  _selected.add(index);
                }
              });
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                FutureBuilder<Uint8List?>(
                  future: asset.thumbnailDataWithSize(const ThumbnailSize.square(200)),
                  builder: (ctx, snap) {
                    if (snap.hasData && snap.data != null) {
                      return Image.memory(snap.data!, fit: BoxFit.cover);
                    }
                    return Container(color: cs.surfaceContainerHighest);
                  },
                ),
                if (asset.type == AssetType.video)
                  Positioned(
                    bottom: 4, right: 4,
                    child: ThemeIcon('videoCamera', color: cs.onSurface, size: 18),
                  ),
                Positioned(
                  top: 4, right: 4,
                  child: Container(
                    width: 24, height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isSelected ? cs.primary : t.hairline,
                      border: Border.all(color: cs.onSurface, width: 1.5),
                    ),
                    child: isSelected
                        ? ThemeIcon('check', selected: true, size: 16, color: cs.onPrimary)
                        : null,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;
  final String icon;
  final bool iconSelected;
  final Color? color;

  const _StatRow({
    required this.label,
    required this.value,
    required this.icon,
    this.iconSelected = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          ThemeIcon(icon, selected: iconSelected, size: 18, color: color ?? cs.onSurface.withAlpha(120)),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: cs.onSurface.withAlpha(120), fontSize: 14)),
          const Spacer(),
          Text(value,
              style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w600, fontSize: 14)),
        ],
      ),
    );
  }
}
