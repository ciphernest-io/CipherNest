import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../config/theme_controller.dart';
import '../../utils/byte_format.dart';
import '../../widgets/theme_icon.dart';
import '../../../services/cache_manager_service.dart';
import '../../../services/cloud/account_registry.dart';
import '../../../services/database_service.dart';

/// A vault-usage-style card for the on-device decrypted-artifact cache.
///
/// The cache is ONE device-wide pool: CipherNest writes its artifacts flat
/// into the temp-dir root (`thumb_*`, `*_decrypted.*`, `video_*.plain*`,
/// picker copies under `file_picker/`), with no account in the filename, and
/// everything else in there is Android/engine plumbing. So the pool is
/// genuinely shared across every account (and every vault) on this device —
/// the card says so plainly. The account toggle attributes the CipherNest
/// portion back to an account by mapping each file's cloudId/fileId token
/// through [DatabaseService.getCacheOwnerMap]; anything unattributable counts
/// as "shared".
class CacheUsageCard extends StatefulWidget {
  const CacheUsageCard({
    super.key,
    this.onClear,
    this.onShowContents,
    this.clearSubtitle,
  });

  /// Clears the cache; rendered as a button inside the card so the number
  /// and the action that changes it sit together.
  final VoidCallback? onClear;

  /// Long-press on the same button: the cache contents sheet.
  final VoidCallback? onShowContents;
  final String? clearSubtitle;

  @override
  State<CacheUsageCard> createState() => _CacheUsageCardState();
}

class _Breakdown {
  final int mine; // CipherNest cache for the selected scope
  final int shared; // app cache not attributable to the selected account
  final int system; // Android / engine caches
  const _Breakdown(this.mine, this.shared, this.system);
  int get total => mine + shared + system;
}

class _CacheUsageCardState extends State<CacheUsageCard> {
  bool _allAccounts = false;
  _Breakdown? _bd;

  @override
  void initState() {
    super.initState();
    CacheManagerService().addListener(_compute);
    _compute();
  }

  @override
  void dispose() {
    CacheManagerService().removeListener(_compute);
    super.dispose();
  }

  /// Extract the identifying token (cloudId or fileId) from a flat cache
  /// filename, or null when the file can't be tied to a vault file.
  static String? _token(String name) {
    if (name.startsWith('thumb_local_') && name.endsWith('.jpg')) {
      return name.substring('thumb_local_'.length, name.length - 4);
    }
    if (name.startsWith('thumb_') && name.endsWith('.jpg')) {
      return name.substring('thumb_'.length, name.length - 4);
    }
    if (name.startsWith('video_')) {
      var rest = name.substring('video_'.length);
      final dot = rest.indexOf('.plain');
      if (dot >= 0) rest = rest.substring(0, dot);
      return rest;
    }
    if (name.endsWith('_decrypted.jpg')) {
      return name.substring(0, name.length - '_decrypted.jpg'.length);
    }
    if (name.endsWith('_decrypted.mp4')) {
      return name.substring(0, name.length - '_decrypted.mp4'.length);
    }
    return null;
  }

  Future<void> _compute() async {
    final active = AccountRegistry().activeAccount?.id;
    // The mine/shared split is only meaningful with more than one account on
    // the device. With a single account every attributable byte is "mine", so
    // there is no phantom "shared / other accounts" slice.
    final multiAccount = AccountRegistry().accounts.length > 1;
    Map<String, String> owners = const {};
    try {
      owners = await DatabaseService().getCacheOwnerMap();
    } catch (_) {
      // DB not ready — fall back to device-wide only.
    }
    int mine = 0, shared = 0, system = 0;
    try {
      final tempDir = await getTemporaryDirectory();
      if (await tempDir.exists()) {
        final rootPath = tempDir.path;
        final pickerPrefix = '$rootPath${Platform.pathSeparator}file_picker';
        await for (final f
            in tempDir.list(recursive: true, followLinks: false)) {
          if (f is! File) continue;
          final inRoot = f.parent.path == rootPath;
          final isPicker = f.path.startsWith(pickerPrefix);
          final len = await f.length();
          if (!(inRoot || isPicker)) {
            system += len;
            continue;
          }
          if (_allAccounts || !multiAccount) {
            mine += len;
            continue;
          }
          final token = isPicker ? null : _token(f.uri.pathSegments.last);
          final owner = token == null ? null : owners[token];
          if (owner != null && owner == active) {
            mine += len;
          } else {
            shared += len;
          }
        }
      }
    } catch (_) {
      // Best-effort scan.
    }
    if (mounted) setState(() => _bd = _Breakdown(mine, shared, system));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = ThemeController().tokens;
    final bd = _bd;

    final multiAccount = AccountRegistry().accounts.length > 1;
    final showSplit = multiAccount && !_allAccounts;
    Color shade(double f) => Color.lerp(cs.primary, tokens.bg, f)!;
    final segments = <_Seg>[
      _Seg(showSplit ? 'This account' : 'CipherNest cache',
          bd?.mine ?? 0, shade(0)),
      if (showSplit)
        _Seg('Shared / other accounts', bd?.shared ?? 0, shade(0.4)),
      _Seg('Android system', bd?.system ?? 0, cs.onSurface.withAlpha(90)),
    ].where((s) => s.bytes > 0).toList();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
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
              ThemeIcon('cached', color: cs.primary, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Cache usage',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600, fontSize: 15)),
              ),
              Text(bd == null ? '—' : formatBytes(bd.total),
                  style: TextStyle(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w600,
                      fontSize: 15)),
            ],
          ),
          // The This account / All accounts toggle only appears with more than
          // one account — with a single account there is nothing to split, and
          // hiding it keeps the card a fixed height.
          if (multiAccount) ...[
            const SizedBox(height: 12),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: SegmentedButton<bool>(
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: const [
                  ButtonSegment(value: false, label: Text('This account')),
                  ButtonSegment(value: true, label: Text('All accounts')),
                ],
                selected: {_allAccounts},
                onSelectionChanged: (s) {
                  setState(() => _allAccounts = s.first);
                  _compute();
                },
              ),
            ),
          ],
          if (segments.isNotEmpty) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 6,
                child: Row(
                  children: segments
                      .map((s) => Expanded(
                          flex: s.bytes, child: Container(color: s.color)))
                      .toList(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: segments
                  .map((s) => Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                                color: s.color, shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 6),
                          Text('${s.label} · ${formatBytes(s.bytes)}',
                              style: TextStyle(
                                  color: cs.onSurface.withAlpha(180),
                                  fontSize: 11)),
                        ],
                      ))
                  .toList(),
            ),
          ],
          if (widget.onClear != null) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.clearSubtitle ?? '',
                    style: TextStyle(
                        color: cs.onSurface.withAlpha(140), fontSize: 11),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: widget.onClear,
                  onLongPress: widget.onShowContents,
                  icon: ThemeIcon('broom', size: 16, color: cs.primary),
                  label: Text('Clear', style: TextStyle(color: cs.onSurface)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: cs.outline),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Seg {
  final String label;
  final int bytes;
  final Color color;
  _Seg(this.label, this.bytes, this.color);
}
