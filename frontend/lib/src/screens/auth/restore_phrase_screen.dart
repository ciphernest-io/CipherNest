import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/key_manager_service.dart';
import '../../config/flags.dart';
import '../../config/routes.dart';
import '../../config/theme_controller.dart';
import '../../utils/wordlists.dart';
import '../../widgets/bip39_autocomplete_row.dart';
import '../../widgets/theme_icon.dart';
import '../cloud_selection/cloud_selection_screen.dart' show CloudSelectionArgs;
import '../subscription/subscription_screen.dart'
    show SubscriptionScreenArgs;
import 'master_password_screen.dart' show MasterPasswordArgs, MasterPasswordMode;

/// Restore flow, phrase entry only. Password is collected on the next
/// screen (reuses [MasterPasswordScreen] in restore mode).
///
/// 12-slot chip grid with per-slot BIP-39 autocomplete. Full-phrase paste
/// distributes across slots; 24-word / short-phrase pastes get friendly
/// rejections. On success pushes [AppRoutes.masterPassword] with the
/// validated mnemonic as an argument.
class RestorePhraseScreen extends StatefulWidget {
  const RestorePhraseScreen({super.key});

  @override
  State<RestorePhraseScreen> createState() => _RestorePhraseScreenState();
}

class _RestorePhraseScreenState extends State<RestorePhraseScreen> {
  static const _slotCount = 12;

  late final List<TextEditingController> _slots;
  late final List<FocusNode> _focusNodes;
  int _focusedSlot = 0;
  Set<String>? _bipSet;

  String? _phraseError;

  @override
  void initState() {
    super.initState();
    _slots = List.generate(_slotCount, (_) => TextEditingController());
    _focusNodes = List.generate(_slotCount, (_) => FocusNode());
    for (int i = 0; i < _slotCount; i++) {
      _focusNodes[i].addListener(() {
        if (_focusNodes[i].hasFocus && _focusedSlot != i) {
          setState(() => _focusedSlot = i);
        }
      });
    }
    Bip39Wordlist.loadSet().then((set) {
      if (!mounted) return;
      setState(() => _bipSet = set);
    });
  }

  @override
  void dispose() {
    for (final c in _slots) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Paste / distribute
  // -------------------------------------------------------------------------

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    _distributePaste(data?.text ?? '');
  }

  void _distributePaste(String raw) {
    final tokens = raw
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return;

    if (tokens.length == 24) {
      _showLengthMismatchDialog(
        title: 'That looks like a hardware-wallet phrase.',
        body:
            'CipherNest uses 12-word recovery phrases, not 24-word. If this is a Ledger or Trezor seed, it is not for CipherNest.',
      );
      return;
    }
    if (tokens.length > _slotCount) {
      _showLengthMismatchDialog(
        title: 'Too many words.',
        body:
            'CipherNest phrases are exactly 12. You pasted ${tokens.length}. Check for extra spaces or accidental duplicates.',
      );
      return;
    }
    if (tokens.length < _slotCount) {
      _showLengthMismatchDialog(
        title: 'Not enough words.',
        body:
            'CipherNest phrases are exactly 12. You pasted ${tokens.length}. Make sure you copied the whole thing.',
      );
      return;
    }

    for (int i = 0; i < _slotCount; i++) {
      _slots[i].text = tokens[i].toLowerCase();
    }
    setState(() => _phraseError = null);
  }

  Future<void> _showLengthMismatchDialog({
    required String title,
    required String body,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Per-slot text handling. Handles auto-advance on space + inline paste.
  // -------------------------------------------------------------------------

  void _onSlotChanged(int slot, String text) {
    // Detect an inline paste: multiple whitespace-separated tokens dropped
    // into this slot in one keystroke. Distribute across all 12.
    if (text.trim().contains(RegExp(r'\s'))) {
      _distributePaste(text);
      return;
    }
    // Auto-advance to next slot when the user hits space.
    if (text.endsWith(' ') && slot < _slotCount - 1) {
      _slots[slot].text = text.trim();
      _slots[slot].selection = TextSelection.collapsed(
        offset: _slots[slot].text.length,
      );
      _focusNodes[slot + 1].requestFocus();
    }
    setState(() => _phraseError = null);
  }

  // -------------------------------------------------------------------------
  // Validation
  // -------------------------------------------------------------------------

  bool _isSlotWordlist(int slot) {
    final w = _slots[slot].text.trim().toLowerCase();
    if (w.isEmpty || _bipSet == null) return false;
    return _bipSet!.contains(w);
  }

  bool _isSlotWrong(int slot) {
    final w = _slots[slot].text.trim().toLowerCase();
    if (w.isEmpty || _bipSet == null) return false;
    return !_bipSet!.contains(w);
  }

  String _assembledPhrase() {
    return _slots.map((c) => c.text.trim().toLowerCase()).join(' ');
  }

  bool get _allSlotsFilled =>
      _slots.every((c) => c.text.trim().isNotEmpty);
  bool get _allSlotsInWordlist =>
      List.generate(_slotCount, _isSlotWordlist).every((b) => b);

  Future<void> _continue() async {
    if (!_allSlotsFilled) {
      setState(() => _phraseError = 'Fill in all 12 words to continue.');
      return;
    }
    if (!_allSlotsInWordlist) {
      final firstBad = List.generate(_slotCount, _isSlotWordlist)
          .indexWhere((ok) => !ok);
      setState(() =>
          _phraseError = "Word #${firstBad + 1} isn't in the BIP-39 wordlist.");
      return;
    }
    final phrase = _assembledPhrase();
    if (!bip39.validateMnemonic(phrase)) {
      setState(() =>
          _phraseError = 'Phrase checksum invalid. Check for typos.');
      return;
    }

    setState(() => _phraseError = null);

    // Reached from the phrase screen mid-signup: the user already chose a
    // password minutes ago, so reuse it. The half-made signup vault is
    // abandoned (nothing uploaded) and the phrase is staged; cloud
    // selection's canary decides whether it commits.
    if (KeyManagerService().hasSignupPassword) {
      await KeyManagerService().abandonSignupForRestore(phrase);
      if (!mounted) return;
      // Paywall slot (Aug 31 ruling): moving ahead from phrase entry.
      if (kPaywallEnabled) {
        Navigator.pushNamedAndRemoveUntil(
          context,
          AppRoutes.subscription,
          (route) => false,
          arguments: const SubscriptionScreenArgs(
            nextRoute: AppRoutes.cloudSelection,
            nextArguments: CloudSelectionArgs.restore,
          ),
        );
      } else {
        Navigator.pushNamedAndRemoveUntil(
          context,
          AppRoutes.cloudSelection,
          (route) => false,
          arguments: CloudSelectionArgs.restore,
        );
      }
      return;
    }

    Navigator.pushNamed(
      context,
      AppRoutes.masterPassword,
      arguments: MasterPasswordArgs(
        mode: MasterPasswordMode.restore,
        mnemonic: phrase,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final phraseComplete = _allSlotsFilled && _allSlotsInWordlist;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        leading: Navigator.canPop(context)
            ? IconButton(
                icon: const ThemeIcon('arrowLeft'),
                onPressed: () => Navigator.pop(context),
              )
            : null,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Enter your recovery phrase.',
                style: text.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Twelve words in the order you saved them. Autocomplete will help. Tap Paste if you copied the whole phrase from a password manager.',
                style: text.bodyMedium?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.72),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _pasteFromClipboard,
                  icon: ThemeIcon(
                    'clipboardText',
                    size: 16,
                    color: cs.primary,
                  ),
                  label: Text(
                    'Paste phrase',
                    style: TextStyle(color: cs.primary),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              _SlotGrid(
                slots: _slots,
                focusNodes: _focusNodes,
                isMatchOf: _isSlotWordlist,
                isWrongOf: _isSlotWrong,
                onChanged: _onSlotChanged,
              ),
              if (_bipSet != null) ...[
                const SizedBox(height: 8),
                Bip39AutocompleteRow(
                  controller: _slots[_focusedSlot],
                  limit: 6,
                ),
              ],
              if (_phraseError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _phraseError!,
                  style: text.bodySmall
                      ?.copyWith(color: ThemeController().tokens.danger),
                ),
              ],
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: phraseComplete ? _continue : null,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text(
                    'Continue',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SlotGrid extends StatelessWidget {
  const _SlotGrid({
    required this.slots,
    required this.focusNodes,
    required this.isMatchOf,
    required this.isWrongOf,
    required this.onChanged,
  });

  final List<TextEditingController> slots;
  final List<FocusNode> focusNodes;
  final bool Function(int slot) isMatchOf;
  final bool Function(int slot) isWrongOf;
  final void Function(int slot, String text) onChanged;

  @override
  Widget build(BuildContext context) {
    // Below 340dp (only the 320dp class; 411 portrait hands us 371) the
    // slot chrome tightens so an 8-letter word stays visible while typed.
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxWidth < 340;
      return Column(
      children: List.generate(4, (row) {
        return Padding(
          padding: EdgeInsets.only(bottom: row == 3 ? 0 : 8),
          child: Row(
            children: List.generate(3, (col) {
              final i = row * 3 + col;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: col == 2 ? 0 : 8),
                  child: _Slot(
                    position: i + 1,
                    controller: slots[i],
                    focusNode: focusNodes[i],
                    isMatch: isMatchOf(i),
                    isWrong: isWrongOf(i),
                    onChanged: (v) => onChanged(i, v),
                    isLast: i == slots.length - 1,
                    compact: compact,
                  ),
                ),
              );
            }),
          ),
        );
      }),
      );
    });
  }
}

class _Slot extends StatelessWidget {
  const _Slot({
    required this.position,
    required this.controller,
    required this.focusNode,
    required this.isMatch,
    required this.isWrong,
    required this.onChanged,
    required this.isLast,
    this.compact = false,
  });

  final int position;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isMatch;
  final bool isWrong;
  final ValueChanged<String> onChanged;
  final bool isLast;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    Color borderColor = cs.outline.withValues(alpha: 0.4);
    if (isMatch) borderColor = t.success;
    if (isWrong) borderColor = t.danger;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(t.rInput),
        border: Border.all(color: borderColor, width: 1.2),
      ),
      child: Row(
        children: [
          SizedBox(
            width: compact ? 14 : 18,
            child: Text(
              '$position',
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.5),
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              textInputAction:
                  isLast ? TextInputAction.done : TextInputAction.next,
              style: TextStyle(
                fontFamily: t.monoFontFamily,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
