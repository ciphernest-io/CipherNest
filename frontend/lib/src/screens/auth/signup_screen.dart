import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:flutter/services.dart';
import '../../../services/key_manager_service.dart';
import '../../config/routes.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _isLoading = false;
  String? _recoveryPhrase; // If not null, account is created, show phrase
  bool _copying = false;

  Future<void> _createAccount() async {
    final password = _passwordController.text;
    final confirm = _confirmController.text;

    if (password.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password must be at least 8 characters')),
      );
      return;
    }

    if (password != confirm) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Passwords do not match')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 1. Generate keys and get the recovery phrase
      final mnemonic = await KeyManagerService().createAccount(password);

      setState(() {
        _isLoading = false;
        _recoveryPhrase = mnemonic;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  void _completeSetup() {
    // Navigate to Cloud Selection after user confirms they saved the phrase
    Navigator.pushReplacementNamed(context, AppRoutes.cloudSelection);
  }

  @override
  Widget build(BuildContext context) {
    // If we have a phrase, show the "Save your Phrase" view
    if (_recoveryPhrase != null) {
      return _buildRecoveryPhaseView();
    }

    // Otherwise, show the "Create Password" view
    return Scaffold(
      appBar: AppBar(title: const Text('Secure your Vault')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Create a Master Password',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'This password encrypts your keys. If you lose it, only your recovery phrase can restore your data.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Master Password',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _confirmController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Confirm Password',
                border: OutlineInputBorder(),
              ),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _createAccount,
                child: _isLoading
                    ? const CircularProgressIndicator()
                    : const Text('Create Account'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecoveryPhaseView() {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Recovery Phrase')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            Icon(PhosphorIcons.shieldCheck(PhosphorIconsStyle.thin), size: 64, color: cs.primary),
            const SizedBox(height: 24),
            Text(
              'Write this down!',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            Text(
              'This 12-word phrase is the ONLY way to recover your data if you forget your password or lose your phone.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.redAccent,
                  ),
            ),
            const SizedBox(height: 32),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: cs.outline),
              ),
              child: Text(
                _recoveryPhrase!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontFamily: 'Courier', // Monospace for readability
                  fontWeight: FontWeight.bold,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _recoveryPhrase!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied to clipboard')),
                );
              },
              icon: Icon(PhosphorIcons.copy(PhosphorIconsStyle.thin)),
              label: const Text('Copy to Clipboard'),
            ),
            const Spacer(),
            CheckboxListTile(
              value: _copying,
              onChanged: (v) => setState(() => _copying = v!),
              title: const Text(
                'I have written down my recovery phrase in a safe place.',
                style: TextStyle(fontSize: 14),
              ),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _copying ? _completeSetup : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _copying ? cs.primary : cs.surfaceContainerHighest,
                  foregroundColor: cs.onPrimary,
                ),
                child: const Text('I saved it. Enter CipherNest.'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}