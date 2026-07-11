import 'package:flutter/material.dart';

import '../config/theme_controller.dart';
import '../utils/wordlists.dart';

/// A small horizontal row of BIP-39 suggestion chips filtered by the
/// controller's current prefix. Empty prefix or an exact wordlist match
/// hides the row so it doesn't pester the user once they've committed to a
/// word. Tapping a chip fills the controller and moves the caret to the end.
///
/// Used by both the recovery-phrase type-back challenge and the restore
/// flow's 12-slot chip grid.
class Bip39AutocompleteRow extends StatefulWidget {
  const Bip39AutocompleteRow({
    super.key,
    required this.controller,
    this.limit = 5,
    this.chipFontSize = 12,
  });

  final TextEditingController controller;
  final int limit;
  final double chipFontSize;

  @override
  State<Bip39AutocompleteRow> createState() => _Bip39AutocompleteRowState();
}

class _Bip39AutocompleteRowState extends State<Bip39AutocompleteRow> {
  List<String> _suggestions = const [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_recompute);
    _recompute();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_recompute);
    super.dispose();
  }

  Future<void> _recompute() async {
    final prefix = widget.controller.text.trim();
    if (prefix.isEmpty) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = const []);
      return;
    }
    final set = await Bip39Wordlist.loadSet();
    if (set.contains(prefix.toLowerCase())) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = const []);
      return;
    }
    final matches =
        await Bip39Wordlist.autocomplete(prefix, limit: widget.limit);
    if (!mounted) return;
    setState(() => _suggestions = matches);
  }

  @override
  Widget build(BuildContext context) {
    if (_suggestions.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: _suggestions
            .map(
              (w) => InkWell(
                onTap: () {
                  widget.controller.text = w;
                  widget.controller.selection =
                      TextSelection.collapsed(offset: w.length);
                },
                borderRadius: BorderRadius.circular(t.rCard),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(t.rCard),
                    border: Border.all(
                      color: cs.outline.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    w,
                    style: TextStyle(
                      fontFamily: t.monoFontFamily,
                      fontSize: widget.chipFontSize,
                      color: cs.onSurface.withValues(alpha: 0.85),
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}
