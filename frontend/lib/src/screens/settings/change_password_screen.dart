import 'package:flutter/material.dart';

import '../../widgets/master_password_field_group.dart';
import '../../widgets/theme_icon.dart';
import '../../../services/key_manager_service.dart';
import '../../../services/notify.dart';

/// Change the master password. This re-wraps the on-device seed blob under a
/// new password; the vault keys and the recovery phrase are unchanged, and
/// the recovery phrase still restores the vault. Requires the current
/// password (no seed exists in memory without it).
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _currentCtrl = TextEditingController();
  String _newPass = '';
  bool _newValid = false;
  bool _obscureCurrent = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _currentCtrl.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      !_busy && _currentCtrl.text.isNotEmpty && _newValid && _newPass.isNotEmpty;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await KeyManagerService()
        .changePassword(_currentCtrl.text, _newPass);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _error = 'Current password is incorrect.';
      });
      return;
    }
    Notify.info('Master password changed');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Change password')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Your recovery phrase and encrypted files are unaffected. Only '
            'the password that unlocks this device changes.',
            style: TextStyle(color: cs.onSurface.withAlpha(160), fontSize: 13),
          ),
          const SizedBox(height: 24),
          Text('Current password',
              style: TextStyle(
                  color: cs.onSurface, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _currentCtrl,
            obscureText: _obscureCurrent,
            autofillHints: const [AutofillHints.password],
            onChanged: (_) => setState(() => _error = null),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              errorText: _error,
              suffixIcon: IconButton(
                icon: ThemeIcon(
                    _obscureCurrent ? 'visibility_off' : 'visibility',
                    color: cs.onSurface.withAlpha(160)),
                onPressed: () =>
                    setState(() => _obscureCurrent = !_obscureCurrent),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text('New password',
              style: TextStyle(
                  color: cs.onSurface, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          MasterPasswordFieldGroup(
            onChanged: (pass, valid) => setState(() {
              _newPass = pass;
              _newValid = valid;
            }),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _canSubmit ? _submit : null,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Change password'),
          ),
        ],
      ),
    );
  }
}
