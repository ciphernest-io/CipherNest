import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';
import '../../../services/key_manager_service.dart';

/// Settings › "View recovery phrase". Re-prompts for the master password,
/// decrypts the persistent password-wrapped mnemonic blob, and shows the 12
/// words. The words live in memory only and are dropped when the screen is
/// disposed; nothing is written anywhere.
class ViewPhraseScreen extends StatefulWidget {
  const ViewPhraseScreen({super.key});

  @override
  State<ViewPhraseScreen> createState() => _ViewPhraseScreenState();
}

class _ViewPhraseScreenState extends State<ViewPhraseScreen> {
  final _passCtrl = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;
  List<String>? _words;

  @override
  void dispose() {
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _reveal() async {
    if (_busy || _passCtrl.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final phrase = await KeyManagerService().revealMnemonic(_passCtrl.text);
    if (!mounted) return;
    if (phrase == null) {
      setState(() {
        _busy = false;
        _error = 'Incorrect password.';
      });
      return;
    }
    setState(() {
      _busy = false;
      _words = phrase.trim().split(RegExp(r'\s+'));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recovery phrase')),
      body: _words == null ? _buildGate() : _buildReveal(),
    );
  }

  Widget _buildGate() {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Enter your master password to view your 12-word recovery phrase. '
          'Anyone with these words can restore your vault, so reveal them only '
          'somewhere private.',
          style: TextStyle(color: cs.onSurface.withAlpha(160), fontSize: 13),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _passCtrl,
          obscureText: _obscure,
          autofocus: true,
          autofillHints: const [AutofillHints.password],
          onChanged: (_) => setState(() => _error = null),
          onSubmitted: (_) => _reveal(),
          decoration: InputDecoration(
            labelText: 'Master password',
            border: const OutlineInputBorder(),
            errorText: _error,
            suffixIcon: IconButton(
              icon: ThemeIcon(_obscure ? 'visibility_off' : 'visibility',
                  color: cs.onSurface.withAlpha(160)),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy || _passCtrl.text.isEmpty ? null : _reveal,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Reveal phrase'),
        ),
      ],
    );
  }

  Widget _buildReveal() {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    final words = _words!;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            ThemeIcon('warning', color: t.warning, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Write these down and keep them offline. Do not screenshot.',
                style:
                    TextStyle(color: cs.onSurface.withAlpha(180), fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 3,
          childAspectRatio: 2.6,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: List.generate(words.length, (i) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(t.rInput),
                border: Border.all(color: cs.outline.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  Text('${i + 1}',
                      style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.45),
                          fontSize: 11,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(words[i],
                          style: TextStyle(
                              fontFamily: t.monoFontFamily,
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            );
          }),
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: words.join(' ')));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Phrase copied. Clear your clipboard after')));
          },
          icon: ThemeIcon('copy', color: cs.primary),
          label: const Text('Copy to clipboard'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
