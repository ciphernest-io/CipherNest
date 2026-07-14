import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';
import 'package:share_plus/share_plus.dart';

import '../../config/routes.dart';
import '../../models/file_model.dart';
import '../../models/share_model.dart';
import '../../../services/share_service.dart';
import '../../../services/subscription_service.dart';

/// Bottom-sheet dialog for creating a new share. Shows expiry dropdown,
/// optional password field, and a "Create link" button. After creation,
/// shows the magic link with copy + share-sheet buttons.
class ShareDialog extends StatefulWidget {
  final CnestFile file;
  const ShareDialog({super.key, required this.file});

  /// Convenience helper to invoke as a modal bottom sheet.
  static Future<void> show(BuildContext context, CnestFile file) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ShareDialog(file: file),
      ),
    );
  }

  @override
  State<ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<ShareDialog> {
  String _expiryLabel = '7 days';
  bool _passwordEnabled = false;
  final _passwordController = TextEditingController();
  bool _creating = false;
  CnestShare? _result;
  String? _error;
  String? _upsell;
  // Bumped when a gated expiry pick is rejected — forces the form field to
  // rebuild from `initialValue`, since its internal state already committed
  // the selection we refused.
  int _expiryFieldEpoch = 0;

  bool get _isPlus => SubscriptionService().isPlus;

  /// Free tier keeps the 7-day default (and anything shorter); longer or
  /// non-expiring links are Plus.
  bool _isGatedExpiry(String label) {
    final d = ShareService.expiryOptions[label];
    return d == null || d > const Duration(days: 7);
  }

  void _showPlusUpsell(String message) {
    setState(() => _upsell = message);
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final expiry = ShareService.expiryOptions[_expiryLabel];
      final password =
          _passwordEnabled && _passwordController.text.isNotEmpty
              ? _passwordController.text
              : null;
      final share = await ShareService().createShare(
        file: widget.file,
        expiry: expiry,
        password: password,
      );
      if (mounted) setState(() => _result = share);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Failed to create share: $e');
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ThemeIcon('shareFat',
                    color: cs.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _result == null ? 'Share file' : 'Share link ready',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.file.filename,
              style: TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 20),
            if (_result == null) ..._buildForm(cs) else ..._buildResult(cs),
          ],
        ),
      ),
    );
  }

  // ---- Form (pre-create) ----

  List<Widget> _buildForm(ColorScheme cs) {
    return [
      Text('Link expires after',
          style: TextStyle(color: cs.onSurface.withAlpha(180), fontSize: 13)),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        key: ValueKey('share-expiry-$_expiryFieldEpoch'),
        initialValue: _expiryLabel,
        items: ShareService.expiryOptions.keys
            .map((k) => DropdownMenuItem(
                  value: k,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(k),
                      if (!_isPlus && _isGatedExpiry(k)) ...[
                        const SizedBox(width: 6),
                        ThemeIcon('lock',
                            size: 13, color: cs.onSurface.withAlpha(120)),
                      ],
                    ],
                  ),
                ))
            .toList(),
        onChanged: (v) {
          if (v == null) return;
          if (!_isPlus && _isGatedExpiry(v)) {
            setState(() => _expiryFieldEpoch++);
            _showPlusUpsell(
                'Links longer than 7 days need CipherNest Plus.');
            return;
          }
          setState(() {
            _expiryLabel = v;
            _upsell = null;
          });
        },
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Switch(
            value: _passwordEnabled,
            onChanged: (v) {
              if (v && !_isPlus) {
                _showPlusUpsell(
                    'Password-protected links need CipherNest Plus.');
                return;
              }
              setState(() {
                _passwordEnabled = v;
                _upsell = null;
              });
            },
          ),
          const SizedBox(width: 8),
          Text('Require password',
              style: TextStyle(color: cs.onSurface, fontSize: 14)),
          if (!_isPlus) ...[
            const SizedBox(width: 6),
            ThemeIcon('lock', size: 13, color: cs.onSurface.withAlpha(120)),
          ],
        ],
      ),
      if (_upsell != null) ...[
        const SizedBox(height: 12),
        _buildUpsellRow(cs),
      ],
      if (_passwordEnabled) ...[
        const SizedBox(height: 8),
        TextField(
          controller: _passwordController,
          obscureText: true,
          decoration: const InputDecoration(
            hintText: 'Password',
            prefixIcon: ThemeIcon('lock'),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Send the password to the recipient through a different channel '
          '(not the same chat where you send the link).',
          style: TextStyle(
              color: cs.onSurface.withAlpha(140), fontSize: 11),
        ),
      ],
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: TextStyle(color: cs.error, fontSize: 12)),
      ],
      const SizedBox(height: 20),
      ElevatedButton.icon(
        onPressed: _creating ? null : _create,
        icon: _creating
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: cs.onPrimary),
              )
            : ThemeIcon('linkSimple'),
        label: Text(_creating ? 'Creating share…' : 'Create link'),
      ),
    ];
  }

  Widget _buildUpsellRow(ColorScheme cs) {
    final t = ThemeController().tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.primary.withAlpha(24),
        borderRadius: BorderRadius.circular(t.rInput),
      ),
      child: Row(
        children: [
          ThemeIcon('workspace_premium', size: 16, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _upsell!,
              style: TextStyle(color: cs.onSurface, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pushNamed(context, AppRoutes.subscription),
            child: const Text('See Plus'),
          ),
        ],
      ),
    );
  }

  // ---- Result (post-create) ----

  List<Widget> _buildResult(ColorScheme cs) {
    final t = ThemeController().tokens;
    final url = _result!.shareUrl;
    return [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(t.rInput),
        ),
        child: SelectableText(
          url,
          style: TextStyle(fontSize: 12, fontFamily: t.monoFontFamily),
          maxLines: 4,
        ),
      ),
      const SizedBox(height: 12),
      if (_result!.hasPassword)
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: t.warning.withAlpha(30),
            borderRadius: BorderRadius.circular(t.rInput),
          ),
          child: Row(
            children: [
              ThemeIcon('warning', color: t.warning, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Send the password separately. The link is useless without it.',
                  style: TextStyle(color: cs.onSurface, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: url));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Link copied')),
                  );
                }
              },
              icon: ThemeIcon('copy'),
              label: const Text('Copy'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () async {
                await Share.share(
                  'View encrypted file via CipherNest:\n$url',
                );
              },
              icon: ThemeIcon('shareFat'),
              label: const Text('Share'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Done'),
      ),
    ];
  }
}
