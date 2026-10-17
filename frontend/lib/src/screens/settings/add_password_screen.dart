import 'package:flutter/material.dart';

import '../../widgets/master_password_field_group.dart';
import '../../../services/app_lock_service.dart';
import '../../../services/key_manager_service.dart';
import '../../../services/notify.dart';

/// Adds a master password to a vault that was created without one. The seed
/// and the recovery phrase are unchanged; from the next open the vault asks
/// for this password, auto-lock applies, and fingerprint unlock can be set up
/// against it.
class AddPasswordScreen extends StatefulWidget {
  const AddPasswordScreen({super.key});

  @override
  State<AddPasswordScreen> createState() => _AddPasswordScreenState();
}

class _AddPasswordScreenState extends State<AddPasswordScreen> {
  String _pass = '';
  bool _valid = false;
  bool _busy = false;

  bool get _canSubmit => !_busy && _valid && _pass.isNotEmpty;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _busy = true);
    try {
      await KeyManagerService().addPassword(_pass);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      Notify.error('Could not add the password. Nothing has changed.');
      return;
    }
    // The vault now has something to lock behind: arm the inactivity timer.
    AppLockService().recordActivity();
    if (!mounted) return;
    Notify.info('Password added. The vault asks for it from now on.');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Add password')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'From the next time it opens, this vault asks for a password. '
            'Your recovery phrase still restores it anywhere and your '
            'encrypted files are unchanged. There is no password reset: if '
            'you forget it, the phrase is the only way back in.',
            style: TextStyle(color: cs.onSurface.withAlpha(160), fontSize: 13),
          ),
          const SizedBox(height: 24),
          Text('New password',
              style: TextStyle(
                  color: cs.onSurface, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          MasterPasswordFieldGroup(
            onChanged: (pass, valid) => setState(() {
              _pass = pass;
              _valid = valid;
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
                : const Text('Add password'),
          ),
        ],
      ),
    );
  }
}
