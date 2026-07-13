import 'package:flutter/material.dart';

import 'theme_icon.dart';

/// Modal password prompt used to arm biometric unlock. The seed exists in
/// memory only during a password entry, so every enable path funnels through
/// this dialog — signup gets no special case.
///
/// Returns the entered password, or null if dismissed. The caller validates
/// it (a wrong password is only detectable by attempting the seed decrypt).
Future<String?> showPasswordConfirmDialog(
  BuildContext context, {
  String title = 'Confirm your password',
  String message =
      'Your master password is needed to set up fingerprint unlock.',
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _PasswordConfirmDialog(title: title, message: message),
  );
}

class _PasswordConfirmDialog extends StatefulWidget {
  final String title;
  final String message;
  const _PasswordConfirmDialog({required this.title, required this.message});

  @override
  State<_PasswordConfirmDialog> createState() => _PasswordConfirmDialogState();
}

class _PasswordConfirmDialogState extends State<_PasswordConfirmDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final pwd = _controller.text;
    if (pwd.isEmpty) return;
    Navigator.pop(context, pwd);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.message,
            style: TextStyle(
                color: cs.onSurface.withAlpha(160), fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            obscureText: true,
            autofocus: true,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: 'Master Password',
              prefixIcon: ThemeIcon('key'),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}
