import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/key_manager_service.dart';
import '../../../services/notify.dart';
import '../../config/routes.dart';
import '../../config/theme_controller.dart';
import '../../utils/wordlists.dart';
import '../../widgets/bip39_autocomplete_row.dart';
import '../../widgets/theme_icon.dart';

/// Signup step 2 of 2. Two internal stages:
///  1. Display: numbered grid of the 12 mnemonic words + advice cards.
///  2. Type-back: three random positions must be typed correctly.
///
/// The mnemonic is passed as `Navigator` route argument. Kept in memory
/// only; never persisted here (KeyManagerService already committed the
/// derived master key).
class RecoveryPhraseScreen extends StatefulWidget {
  const RecoveryPhraseScreen({super.key, required this.mnemonic});

  final String mnemonic;

  @override
  State<RecoveryPhraseScreen> createState() => _RecoveryPhraseScreenState();
}

class _RecoveryPhraseScreenState extends State<RecoveryPhraseScreen> {
  int _stage = 1;
  late final List<String> _words = widget.mnemonic.trim().split(RegExp(r'\s+'));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Forward-only: the password is committed and the phrase is being
      // shown, so there is nothing to go back to. Stage 2 returns to
      // stage 1 only via "Show phrase again".
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          // F1 escape (stage 1 only): restoring an existing vault stays
          // reachable until the phrase is proven. Pushed, not replaced, so
          // the restore screen's back arrow returns here with this vault
          // intact; the signup vault is abandoned only when the user
          // actually continues with a phrase over there.
          if (_stage == 1)
            TextButton(
              onPressed: () => Navigator.pushNamed(context, AppRoutes.restore),
              child: const Text('Have a phrase?'),
            ),
        ],
      ),
      body: SafeArea(
        child: _stage == 1
            ? _DisplayStage(
                words: _words,
                onContinue: () => setState(() => _stage = 2),
              )
            : _TypeBackStage(
                words: _words,
                onSuccess: () async {
                  // Wipes the encrypted-mnemonic blob + clears the
                  // signup-in-progress flag. Must run before we hand off
                  // to cloud selection — the recovery obligation is met.
                  await KeyManagerService().markRecoveryShown();
                  if (!context.mounted) return;
                  Navigator.pushReplacementNamed(
                    context,
                    AppRoutes.cloudSelection,
                  );
                },
                onShowAgain: () => setState(() => _stage = 1),
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stage 1 — Display
// ---------------------------------------------------------------------------

class _DisplayStage extends StatelessWidget {
  const _DisplayStage({required this.words, required this.onContinue});

  final List<String> words;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    // ~594dp of content: a plain column on every FHD phone (body ~763),
    // with the CTA pinned to the bottom by the Spacer. The scroll wrapper
    // is a no-op there and only engages on 360x640-class bodies (~512).
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight - 32),
          child: IntrinsicHeight(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Your recovery phrase',
                  textAlign: TextAlign.center,
                  style: text.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'These twelve words are the only key to your vault. Store them somewhere safe and offline. There is no reset: if they are lost, the files cannot be recovered.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.72),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),
                _WordGrid(words: words),
                const SizedBox(height: 8),
                Center(
                  child: TextButton.icon(
                    icon: ThemeIcon('copy', size: 16, color: cs.primary),
                    label: Text(
                      'Copy to clipboard',
                      style: TextStyle(color: cs.primary),
                    ),
                    onPressed: () => _confirmCopy(context, words.join(' ')),
                  ),
                ),
                const SizedBox(height: 12),
                const _AdviceRow(icon: 'notebook', text: 'Write it down on paper.'),
                const SizedBox(height: 6),
                const _AdviceRow(
                  icon: 'key',
                  text: 'Or keep it in a password manager.',
                ),
                const SizedBox(height: 6),
                _AdviceRow(
                  icon: 'warning',
                  iconTint: ThemeController().tokens.warning,
                  text: "We wouldn't recommend emailing or texting it to yourself.",
                ),
                const Spacer(),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: onContinue,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: const Text(
                      "I saved it. Test me.",
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmCopy(BuildContext context, String phrase) async {
    final cs = Theme.of(context).colorScheme;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Copy to clipboard?'),
        content: const Text(
          'Other apps can read the clipboard, and some phones sync it to the cloud. Paste it into your password manager right away, then clear the clipboard.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: cs.error),
            child: const Text('Copy'),
          ),
        ],
      ),
    );
    if (proceed == true) {
      await Clipboard.setData(ClipboardData(text: phrase));
      Notify.info('Copied. Clear your clipboard once it is saved.');
    }
  }
}

class _WordGrid extends StatelessWidget {
  const _WordGrid({required this.words});
  final List<String> words;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    // Tile HEIGHT is what must stay constant, not the aspect ratio: the
    // original 2.6 was tuned at 411dp (tile 115.67 wide -> 44.5 tall).
    // Deriving the ratio from the actual tile width keeps 44.5dp at every
    // width, so an 8-letter word still gets a full text line at 320dp
    // (2.6 there gave 32.8dp tiles and clipped the phrase).
    return LayoutBuilder(builder: (context, constraints) {
      const refTileWidth = (411.0 - 48 - 16) / 3;
      const refTileHeight = refTileWidth / 2.6;
      final tileWidth = (constraints.maxWidth - 16) / 3;
      return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 3,
      childAspectRatio: tileWidth / refTileHeight,
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
              Text(
                '${i + 1}',
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.45),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              // Never ellipsize a recovery word: below ~77dp of text width
              // the glyphs shrink instead (no-op at 411, where every
              // BIP-39 word fits at 14pt).
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    words[i],
                    style: TextStyle(
                      fontFamily: t.monoFontFamily,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      }),
      );
    });
  }
}

class _AdviceRow extends StatelessWidget {
  const _AdviceRow({required this.icon, required this.text, this.iconTint});

  final String icon;
  final String text;
  final Color? iconTint;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        ThemeIcon(
          icon,
          size: 20,
          color: iconTint ?? cs.primary,
          selected: iconTint == null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.85),
                ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Stage 2 — Type-back challenge
// ---------------------------------------------------------------------------

class _TypeBackStage extends StatefulWidget {
  const _TypeBackStage({
    required this.words,
    required this.onSuccess,
    required this.onShowAgain,
  });

  final List<String> words;
  final Future<void> Function() onSuccess;
  final VoidCallback onShowAgain;

  @override
  State<_TypeBackStage> createState() => _TypeBackStageState();
}

class _TypeBackStageState extends State<_TypeBackStage> {
  late final List<int> _positions;
  late final List<TextEditingController> _controllers;
  Set<String>? _bipSet;

  @override
  void initState() {
    super.initState();
    final rand = Random.secure();
    final pool = List<int>.generate(widget.words.length, (i) => i)
      ..shuffle(rand);
    _positions = pool.take(3).toList()..sort();
    _controllers = List.generate(3, (_) => TextEditingController());
    for (final c in _controllers) {
      c.addListener(() => setState(() {}));
    }
    Bip39Wordlist.loadSet().then((s) {
      if (!mounted) return;
      setState(() => _bipSet = s);
    });
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  bool _isMatch(int slot) {
    final entered = _controllers[slot].text.trim().toLowerCase();
    final expected = widget.words[_positions[slot]].toLowerCase();
    return entered == expected;
  }

  bool _isWrong(int slot) {
    final entered = _controllers[slot].text.trim().toLowerCase();
    if (entered.isEmpty) return false;
    // Wrong once entered word is in the wordlist but not the expected one,
    // OR once it's long enough that autocomplete can't rescue it.
    final inList = _bipSet?.contains(entered) ?? false;
    if (inList && entered != widget.words[_positions[slot]].toLowerCase()) {
      return true;
    }
    return false;
  }

  bool get _allCorrect =>
      _isMatch(0) && _isMatch(1) && _isMatch(2);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Prove you saved it.',
            textAlign: TextAlign.center,
            style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Type words #${_positions[0] + 1}, #${_positions[1] + 1}, and #${_positions[2] + 1} from your recovery phrase.',
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.72),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 24),
          for (int i = 0; i < 3; i++) ...[
            _TypeBackSlot(
              position: _positions[i] + 1,
              controller: _controllers[i],
              status: _isMatch(i)
                  ? _SlotStatus.correct
                  : _isWrong(i)
                      ? _SlotStatus.wrong
                      : _SlotStatus.neutral,
            ),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _allCorrect
                  ? () => _handleSuccess(context)
                  : null,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: const Text(
                'Enter CipherNest.',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: widget.onShowAgain,
            child: Text(
              'Show phrase again',
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSuccess(BuildContext context) async {
    // Defensive: shouldn't be reachable with disabled CTA, but if the state
    // race ever slips through, catch it.
    if (!_allCorrect) {
      await showModalBottomSheet<void>(
        context: context,
        builder: (ctx) => Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "See? That's why we made you do this. Go save it properly. We'll wait.",
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  widget.onShowAgain();
                },
                child: const Text('Show phrase again'),
              ),
            ],
          ),
        ),
      );
      return;
    }
    await widget.onSuccess();
  }
}

enum _SlotStatus { neutral, correct, wrong }

class _TypeBackSlot extends StatelessWidget {
  const _TypeBackSlot({
    required this.position,
    required this.controller,
    required this.status,
  });

  final int position;
  final TextEditingController controller;
  final _SlotStatus status;

  @override
  Widget build(BuildContext context) {
    final t = ThemeController().tokens;
    Widget? suffix;
    Color? borderColor;
    switch (status) {
      case _SlotStatus.correct:
        suffix = Padding(
          padding: const EdgeInsets.all(12),
          child: ThemeIcon(
            'checkCircle',
            selected: true,
            size: 20,
            color: t.success,
          ),
        );
        borderColor = t.success;
      case _SlotStatus.wrong:
        suffix = Padding(
          padding: const EdgeInsets.all(12),
          child: ThemeIcon(
            'xCircle',
            selected: true,
            size: 20,
            color: t.danger,
          ),
        );
        borderColor = t.danger;
      case _SlotStatus.neutral:
        suffix = null;
        borderColor = null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          autocorrect: false,
          textCapitalization: TextCapitalization.none,
          decoration: InputDecoration(
            labelText: 'Word #$position',
            border: const OutlineInputBorder(),
            enabledBorder: borderColor != null
                ? OutlineInputBorder(
                    borderSide: BorderSide(color: borderColor, width: 1.5),
                  )
                : null,
            focusedBorder: borderColor != null
                ? OutlineInputBorder(
                    borderSide: BorderSide(color: borderColor, width: 1.8),
                  )
                : null,
            suffixIcon: suffix,
          ),
        ),
        Bip39AutocompleteRow(controller: controller),
      ],
    );
  }
}

