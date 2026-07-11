import 'package:flutter/material.dart';

import '../../widgets/theme_icon.dart';
import '../../config/routes.dart';
import '../../../services/cloud/account_registry.dart';
import '../../../services/key_manager_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  Future<void> _loginWithPassword() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final success =
          await KeyManagerService().unlock(_passwordController.text);
      if (success && mounted) {
        await _routeAfterUnlock();
      } else {
        setState(() => _error = "Incorrect password");
      }
    } on PublicKeyMismatchException {
      // Stored vault public key doesn't match the recovery seed — refuse to
      // proceed rather than risk encrypting to a tampered key.
      setState(() => _error =
          'Vault key integrity check failed. Do not sync. Reinstall and '
          'restore from your recovery phrase.');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// After a successful unlock, decide where to land:
  ///   - Signup was interrupted mid-flow (killed between password and
  ///     recovery phrase) → resume with the recovery phrase screen.
  ///   - Otherwise route to home if an active cloud account is registered,
  ///     or to reconnect if not.
  Future<void> _routeAfterUnlock() async {
    if (await KeyManagerService().hasSignupInProgress()) {
      final mnemonic =
          await KeyManagerService().retrieveMnemonicIfPending();
      if (mnemonic != null) {
        if (!mounted) return;
        Navigator.pushReplacementNamed(
          context,
          AppRoutes.recoveryPhrase,
          arguments: mnemonic,
        );
        return;
      }
      // Blob missing / corrupt — flag is stale. Clear it so we don't
      // retry forever, then fall through to the normal routing below.
      debugPrint(
        'Signup-in-progress flag set but mnemonic irrecoverable — clearing.',
      );
      await KeyManagerService().markRecoveryShown();
    }

    if (!mounted) return;
    final hasActive = AccountRegistry().activeAccount != null;
    Navigator.pushReplacementNamed(
      context,
      hasActive ? AppRoutes.home : AppRoutes.reconnect,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ThemeIcon('lockKey', size: 80, color: cs.primary),
              const SizedBox(height: 32),
              
              Text(
                'Welcome Back',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 48),

              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Master Password',
                  errorText: _error,
                  border: const OutlineInputBorder(),
                  prefixIcon: ThemeIcon('key'),
                ),
              ),
              const SizedBox(height: 24),

              ElevatedButton(
                onPressed: _isLoading ? null : _loginWithPassword,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isLoading
                  ? const CircularProgressIndicator()
                  : const Text('Unlock Vault'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}