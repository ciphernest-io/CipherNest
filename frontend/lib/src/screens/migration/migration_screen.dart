import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../config/routes.dart';
import '../../config/theme.dart';
import '../../../services/migration_service.dart';

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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Media permissions required')),
        );
        setState(() => _phase = _MigrationPhase.choosing);
      }
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

    final result = await MigrationService().runMigration(
      assets: _assets,
      onProgress: (progress) {
        if (mounted) setState(() => _progress = progress);
      },
    );

    if (mounted) {
      setState(() {
        _result = result;
        _phase = _MigrationPhase.complete;
      });
    }
  }

  void _pause() {
    MigrationService().pause();
    setState(() => _phase = _MigrationPhase.paused);
  }

  void _resume() {
    MigrationService().resume();
    setState(() => _phase = _MigrationPhase.migrating);
  }

  void _cancel() {
    MigrationService().cancel();
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

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
          title: const Text('Migrate Gallery'),
          automaticallyImplyLeading: _phase != _MigrationPhase.migrating,
          leading: _phase == _MigrationPhase.selectingAlbums ||
                  _phase == _MigrationPhase.ready
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        const Icon(Icons.photo_library, color: Colors.cyanAccent, size: 48),
        const SizedBox(height: 16),
        const Text(
          'Import Your Gallery',
          style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'Choose what to migrate into CipherNest. '
          'Files already in your vault will be skipped automatically.',
          style: TextStyle(color: Colors.grey[400], fontSize: 14),
        ),
        const SizedBox(height: 32),
        _MigrationOption(
          icon: Icons.all_inclusive,
          title: 'Entire Gallery',
          subtitle: 'Encrypt all photos and videos on this device',
          onTap: _scanFullGallery,
        ),
        const SizedBox(height: 12),
        _MigrationOption(
          icon: Icons.photo_album,
          title: 'Select Albums',
          subtitle: 'Choose specific albums to migrate',
          onTap: _showAlbumPicker,
        ),
        const SizedBox(height: 12),
        _MigrationOption(
          icon: Icons.touch_app,
          title: 'Pick Photos Manually',
          subtitle: 'Hand-pick individual photos and videos',
          onTap: _pickManualPhotos,
        ),
      ],
    );
  }

  // --- PHASE: Album selector ---
  Widget _buildAlbumSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Select Albums',
          style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          '${_selectedAlbumIndices.length} album${_selectedAlbumIndices.length == 1 ? '' : 's'} selected',
          style: const TextStyle(color: Colors.grey, fontSize: 14),
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
                activeColor: Colors.cyanAccent,
                checkColor: Colors.black,
                title: Text(album.name, style: const TextStyle(color: Colors.white)),
                subtitle: Text(
                  '${album.count} item${album.count == 1 ? '' : 's'}',
                  style: const TextStyle(color: Colors.grey),
                ),
                secondary: const Icon(Icons.photo_album, color: Colors.grey),
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
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.grey[800],
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 24),
          Text('Scanning your gallery...', style: TextStyle(color: Colors.white, fontSize: 18)),
          SizedBox(height: 8),
          Text('This may take a moment for large libraries', style: TextStyle(color: Colors.grey, fontSize: 14)),
        ],
      ),
    );
  }

  // --- PHASE: Ready to migrate ---
  Widget _buildReady() {
    if (_assets.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle, color: Colors.greenAccent, size: 64),
            const SizedBox(height: 16),
            const Text('All caught up!',
                style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('All selected photos are already in CipherNest.',
                style: TextStyle(color: Colors.grey, fontSize: 14), textAlign: TextAlign.center),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white),
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
        const Text('Ready to Migrate',
            style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('Encrypt and upload the selected media to CipherNest.',
            style: TextStyle(color: Colors.grey[400], fontSize: 14)),
        const SizedBox(height: 32),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            children: [
              _StatRow(label: 'Photos', value: '$photoCount', icon: Icons.image),
              if (videoCount > 0)
                _StatRow(label: 'Videos', value: '$videoCount', icon: Icons.videocam),
              _StatRow(label: 'Total Size', value: _formatBytes(_totalBytes), icon: Icons.storage),
              _StatRow(label: 'Estimated Time', value: '~${_formatDuration(estimatedDuration)}', icon: Icons.timer),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text('You can pause or cancel at any time. Already-uploaded files will not be affected.',
            style: TextStyle(color: Colors.grey[600], fontSize: 12)),
        const Spacer(),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton.icon(
            onPressed: _startMigration,
            icon: const Icon(Icons.lock, color: Colors.white),
            label: const Text('Start Migration', style: TextStyle(fontSize: 16)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  // --- PHASE: Migrating (and Paused) ---
  Widget _buildMigrating() {
    final p = _progress;
    final fraction = p != null && p.total > 0 ? p.current / p.total : 0.0;
    final percent = (fraction * 100).toStringAsFixed(0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Text(
          _phase == _MigrationPhase.paused ? 'Paused' : 'Migrating...',
          style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        if (p != null)
          Text('Encrypting: ${p.currentFileName}',
              style: const TextStyle(color: Colors.grey, fontSize: 13),
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
                    backgroundColor: Colors.white10,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      _phase == _MigrationPhase.paused ? Colors.orangeAccent : Colors.cyanAccent,
                    ),
                  ),
                ),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('$percent%',
                        style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold)),
                    if (p != null)
                      Text('${p.current} / ${p.total}', style: const TextStyle(color: Colors.grey, fontSize: 14)),
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
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              children: [
                _StatRow(label: 'Secured', value: '${p.synced}', icon: Icons.check_circle, color: Colors.greenAccent),
                if (p.failed > 0)
                  _StatRow(label: 'Failed', value: '${p.failed}', icon: Icons.error, color: Colors.redAccent),
                _StatRow(label: 'Uploaded', value: _formatBytes(p.bytesUploaded), icon: Icons.cloud_upload),
                _StatRow(label: 'ETA', value: _formatDuration(p.eta), icon: Icons.timer),
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
                  foregroundColor: Colors.redAccent,
                  side: const BorderSide(color: Colors.redAccent),
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
                  backgroundColor: _phase == _MigrationPhase.paused ? Colors.cyanAccent : Colors.orangeAccent,
                  foregroundColor: Colors.black,
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
    final r = _result;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            r != null && r.failed == 0 ? Icons.check_circle : Icons.info_outline,
            color: r != null && r.failed == 0 ? Colors.greenAccent : Colors.orangeAccent,
            size: 72,
          ),
          const SizedBox(height: 20),
          Text(
            r != null && r.failed == 0 ? 'Migration Complete' : 'Migration Finished',
            style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          if (r != null)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                children: [
                  _StatRow(label: 'Secured', value: '${r.synced}', icon: Icons.check_circle, color: Colors.greenAccent),
                  if (r.failed > 0)
                    _StatRow(label: 'Failed', value: '${r.failed}', icon: Icons.error, color: Colors.redAccent),
                  if (r.skipped > 0)
                    _StatRow(label: 'Skipped', value: '${r.skipped}', icon: Icons.skip_next, color: Colors.grey),
                ],
              ),
            ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pushNamedAndRemoveUntil(context, AppRoutes.home, (route) => false),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
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
            child: const Text('Cancel', style: TextStyle(color: Colors.red)),
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
  final IconData icon;
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.cyanAccent, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 13)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
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
                color: _selected.isEmpty ? Colors.grey : Colors.cyanAccent,
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
                    return Container(color: Colors.grey[900]);
                  },
                ),
                if (asset.type == AssetType.video)
                  const Positioned(
                    bottom: 4, right: 4,
                    child: Icon(Icons.videocam, color: Colors.white, size: 18),
                  ),
                Positioned(
                  top: 4, right: 4,
                  child: Container(
                    width: 24, height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isSelected ? Colors.cyanAccent : Colors.black38,
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: isSelected
                        ? const Icon(Icons.check, size: 16, color: Colors.black)
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
  final IconData icon;
  final Color? color;

  const _StatRow({
    required this.label,
    required this.value,
    required this.icon,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color ?? Colors.grey),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 14)),
          const Spacer(),
          Text(value,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
        ],
      ),
    );
  }
}
