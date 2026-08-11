import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';

import '../../models/share_model.dart';
import '../../../services/notify.dart';
import '../../../services/share_service.dart';

class ActiveSharesScreen extends StatefulWidget {
  const ActiveSharesScreen({super.key});

  @override
  State<ActiveSharesScreen> createState() => _ActiveSharesScreenState();
}

class _ActiveSharesScreenState extends State<ActiveSharesScreen> {
  late Future<List<CnestShare>> _future;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() => _future = ShareService().listShares());
  }

  Future<void> _revoke(CnestShare share) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke share?'),
        content: const Text(
          'The link will stop working immediately. Recipients who already '
          'downloaded the file are not affected.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Revoke',
                  style: TextStyle(
                      color: Theme.of(ctx).colorScheme.error))),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ShareService().revokeShare(share.id);
      _refresh();
    } catch (e) {
      Notify.error('Revoke failed: $e');
    }
  }

  String _expiryLabel(CnestShare share) {
    if (share.expiresAt == null) return 'Never expires';
    final remaining = share.expiresAt!.difference(DateTime.now());
    if (remaining.isNegative) return 'Expired';
    if (remaining.inDays > 0) return 'Expires in ${remaining.inDays}d';
    if (remaining.inHours > 0) return 'Expires in ${remaining.inHours}h';
    return 'Expires in ${remaining.inMinutes}m';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Active Shares'),
        actions: [
          IconButton(
            icon: ThemeIcon('arrowsClockwise'),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<List<CnestShare>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final shares = snap.data!;
          if (shares.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ThemeIcon('linkSimple',
                      size: 64, color: cs.onSurface.withAlpha(80)),
                  const SizedBox(height: 16),
                  Text('No active shares',
                      style: TextStyle(color: cs.onSurface.withAlpha(140))),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: shares.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final share = shares[i];
              return Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(t.rInput),
                  border: Border.all(color: cs.outline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        ThemeIcon(
                          share.hasPassword ? 'lock' : 'linkSimple',
                          color: cs.primary,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            share.hasPassword
                                ? 'Password-protected'
                                : 'Public link',
                            style: TextStyle(
                                color: cs.onSurface,
                                fontWeight: FontWeight.w600,
                                fontSize: 14),
                          ),
                        ),
                        Text(
                          _expiryLabel(share),
                          style: TextStyle(
                              color: share.isExpired
                                  ? cs.error
                                  : cs.onSurface.withAlpha(140),
                              fontSize: 11),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      share.shareUrl,
                      style: TextStyle(
                          fontSize: 11, fontFamily: t.monoFontFamily),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        TextButton.icon(
                          icon: ThemeIcon('copy', size: 14),
                          label: const Text('Copy'),
                          onPressed: () async {
                            await Clipboard.setData(
                                ClipboardData(text: share.shareUrl));
                            Notify.info('Link copied');
                          },
                        ),
                        const Spacer(),
                        TextButton.icon(
                          icon: ThemeIcon('trash',
                              size: 14, color: cs.error),
                          label: Text('Revoke',
                              style: TextStyle(color: cs.error)),
                          onPressed: () => _revoke(share),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
