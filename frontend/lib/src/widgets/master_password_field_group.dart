import 'package:flutter/material.dart';

import '../config/theme.dart' show AppColors;
import '../utils/wordlists.dart';
import 'password_strength_meter.dart';
import 'theme_icon.dart';

/// Password + confirm-password inputs with eye toggles, a live strength
/// meter, and a four-rule checklist. The consumer supplies an [onChanged]
/// callback that fires on every keystroke with the current password value
/// and whether all rules pass.
///
/// The four rules (per Appendix A):
///   1. Length >= 8 characters.
///   2. Class variety: 3 of {lower, upper, digit, symbol}; OR passphrase
///      mode: 4+ space-separated tokens totalling 16+ chars.
///   3. Not in the top-10k common passwords blacklist.
///   4. Confirmation matches exactly.
class MasterPasswordFieldGroup extends StatefulWidget {
  const MasterPasswordFieldGroup({
    super.key,
    required this.onChanged,
    this.autofocus = true,
  });

  final void Function(String password, bool isValid) onChanged;
  final bool autofocus;

  @override
  State<MasterPasswordFieldGroup> createState() =>
      _MasterPasswordFieldGroupState();
}

class _MasterPasswordFieldGroupState extends State<MasterPasswordFieldGroup> {
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscurePass = true;
  bool _obscureConfirm = true;
  Set<String>? _blacklist;

  @override
  void initState() {
    super.initState();
    _passCtrl.addListener(_notify);
    _confirmCtrl.addListener(_notify);
    PasswordBlacklist.load().then((set) {
      if (!mounted) return;
      setState(() => _blacklist = set);
      _notify();
    });
  }

  @override
  void dispose() {
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _notify() {
    final rules = _PasswordRules.evaluate(
      _passCtrl.text,
      _confirmCtrl.text,
      _blacklist,
    );
    widget.onChanged(_passCtrl.text, rules.isValid);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rules = _PasswordRules.evaluate(
      _passCtrl.text,
      _confirmCtrl.text,
      _blacklist,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _passCtrl,
          obscureText: _obscurePass,
          autofocus: widget.autofocus,
          decoration: InputDecoration(
            labelText: 'Master password',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: ThemeIcon(
                _obscurePass ? 'visibility_off' : 'visibility',
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
              onPressed: () =>
                  setState(() => _obscurePass = !_obscurePass),
            ),
          ),
        ),
        const SizedBox(height: 12),
        PasswordStrengthMeter(
          score: rules.score,
          label: _passCtrl.text.isEmpty
              ? null
              : PasswordStrengthLabel.forScore(rules.score),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _confirmCtrl,
          obscureText: _obscureConfirm,
          decoration: InputDecoration(
            labelText: 'Confirm password',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: ThemeIcon(
                _obscureConfirm ? 'visibility_off' : 'visibility',
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
              onPressed: () =>
                  setState(() => _obscureConfirm = !_obscureConfirm),
            ),
          ),
        ),
        const SizedBox(height: 20),
        _RuleRow(label: '8+ characters', passed: rules.lengthOk),
        _RuleRow(
          label: 'Mix letters, numbers, symbols. Or use a passphrase.',
          passed: rules.varietyOk,
        ),
        _RuleRow(
          label: "Not one of the world's 10,000 most-common passwords",
          passed: rules.notCommon,
        ),
        _RuleRow(label: 'Confirmation matches', passed: rules.confirmOk),
      ],
    );
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({required this.label, required this.passed});

  final String label;
  final bool passed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tint = passed
        ? AppColors.success
        : cs.onSurface.withValues(alpha: 0.4);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          ThemeIcon('checkCircle', selected: passed, size: 18, color: tint),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: passed
                        ? cs.onSurface
                        : cs.onSurface.withValues(alpha: 0.6),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PasswordRules {
  const _PasswordRules._({
    required this.lengthOk,
    required this.varietyOk,
    required this.notCommon,
    required this.confirmOk,
    required this.score,
  });

  final bool lengthOk;
  final bool varietyOk;
  final bool notCommon;
  final bool confirmOk;
  final int score;

  bool get isValid => lengthOk && varietyOk && notCommon && confirmOk;

  factory _PasswordRules.evaluate(
    String pass,
    String confirm,
    Set<String>? blacklist,
  ) {
    final len = pass.length;
    final lengthOk = len >= 8;

    final hasLower = pass.contains(RegExp(r'[a-z]'));
    final hasUpper = pass.contains(RegExp(r'[A-Z]'));
    final hasDigit = pass.contains(RegExp(r'[0-9]'));
    final hasSymbol = pass.contains(RegExp(r'[^a-zA-Z0-9]'));
    final classes = [hasLower, hasUpper, hasDigit, hasSymbol]
        .where((b) => b)
        .length;

    final tokens = pass.trim().isEmpty
        ? 0
        : pass
            .trim()
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .length;
    final isPassphrase = tokens >= 4 && pass.length >= 16;
    final varietyOk = classes >= 3 || isPassphrase;

    // If the blacklist hasn't loaded yet, don't fail the rule optimistically;
    // the field group will re-notify once it finishes loading.
    final notCommon = pass.isNotEmpty &&
        (blacklist == null || !blacklist.contains(pass));

    final confirmOk = confirm.isNotEmpty && pass == confirm;

    // Score reflects password STRENGTH — length, class variety, blacklist
    // presence — plus a bonus tier for very-long / passphrase-heavy inputs.
    // Confirmation match is a separate CTA-gating rule; it does not affect
    // the meter (typing the same value twice does not make the password any
    // stronger).
    int score = 0;
    if (lengthOk) score++;
    if (varietyOk) score++;
    if (notCommon) score++;
    if (score == 3 && (pass.length >= 16 || (isPassphrase && tokens >= 5))) {
      score++;
    }

    return _PasswordRules._(
      lengthOk: lengthOk,
      varietyOk: varietyOk,
      notCommon: notCommon,
      confirmOk: confirmOk,
      score: score,
    );
  }
}
