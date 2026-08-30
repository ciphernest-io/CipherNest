import 'package:flutter/material.dart';

import '../config/theme_controller.dart';
import 'password_strength_meter.dart';
import 'theme_icon.dart';

/// Password + confirm-password inputs with eye toggles, a live strength
/// meter, and a rule checklist. The consumer supplies an [onChanged]
/// callback that fires on every keystroke with the current password value
/// and whether all rules pass.
///
/// This is a DEVICE password (the recovery phrase is the key), so the
/// rules are the plain ones:
///   1. 8 to 20 characters.
///   2. At least one uppercase letter.
///   3. At least one lowercase letter.
///   4. At least one number or symbol.
///   5. Confirmation matches exactly.
class MasterPasswordFieldGroup extends StatefulWidget {
  const MasterPasswordFieldGroup({
    super.key,
    required this.onChanged,
    this.autofocus = false,
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

  @override
  void initState() {
    super.initState();
    _passCtrl.addListener(_notify);
    _confirmCtrl.addListener(_notify);
  }

  @override
  void dispose() {
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _notify() {
    final rules = _PasswordRules.evaluate(_passCtrl.text, _confirmCtrl.text);
    widget.onChanged(_passCtrl.text, rules.isValid);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rules = _PasswordRules.evaluate(_passCtrl.text, _confirmCtrl.text);

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
        _RuleRow(label: '8 to 20 characters', passed: rules.lengthOk),
        _RuleRow(label: 'At least one uppercase letter', passed: rules.upperOk),
        _RuleRow(label: 'At least one lowercase letter', passed: rules.lowerOk),
        _RuleRow(label: 'At least one number or special character', passed: rules.digitOrSymbolOk),
        _RuleRow(label: 'Passwords match', passed: rules.confirmOk),
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
    final t = ThemeController().tokens;
    final tint = passed
        ? t.success
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
    required this.upperOk,
    required this.lowerOk,
    required this.digitOrSymbolOk,
    required this.confirmOk,
  });

  final bool lengthOk;
  final bool upperOk;
  final bool lowerOk;
  final bool digitOrSymbolOk;
  final bool confirmOk;

  bool get isValid =>
      lengthOk && upperOk && lowerOk && digitOrSymbolOk && confirmOk;

  /// Meter score 0..4: one point per composition rule. Confirmation match
  /// gates the CTA but is not strength (typing it twice adds nothing).
  int get score =>
      [lengthOk, upperOk, lowerOk, digitOrSymbolOk].where((b) => b).length;

  factory _PasswordRules.evaluate(String pass, String confirm) {
    final len = pass.length;
    return _PasswordRules._(
      lengthOk: len >= 8 && len <= 20,
      upperOk: pass.contains(RegExp(r'[A-Z]')),
      lowerOk: pass.contains(RegExp(r'[a-z]')),
      digitOrSymbolOk: pass.contains(RegExp(r'[^a-zA-Z]')),
      confirmOk: confirm.isNotEmpty && pass == confirm,
    );
  }
}
