import 'package:flutter/material.dart';

import '../../widgets/theme_icon.dart';
import '../../config/routes.dart';
import '../../../services/app_lock_service.dart';
import '../../../services/biometric_unlock_service.dart';
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

  /// Biometric wrap is present and healthy — show the button + auto-fire.
  bool _bioAvailable = false;

  /// Info line under the form (invalidation / lockout), distinct from
  /// [_error] so a fingerprint problem never masks a wrong-password error.
  String? _bioNotice;

  bool _bioPromptInFlight = false;

  @override
  void initState() {
    super.initState();
    _initBiometric();
  }

  /// Probes the wrap BEFORE offering the prompt so an invalidated key is a
  /// clear message instead of a doomed fingerprint dialog.
  Future<void> _initBiometric() async {
    final svc = BiometricUnlockService();
    if (!await svc.isEnabled()) return;
    final armed = await svc.checkArmed();
    if (!mounted) return;
    if (armed == BiometricArmedState.armed) {
      setState(() => _bioAvailable = true);
      // Let the screen settle before the OS sheet slides over it.
      await Future.delayed(const Duration(milliseconds: 350));
      if (mounted) _unlockWithBiometric();
    } else {
      // Enrollment change (or OEM deleted the key). Wipe the dead wrap and
      // say exactly what happened. The password wrap is untouched.
      await KeyManagerService().disableBiometric();
      setState(() => _bioNotice =
          'Your device security settings changed. Sign in with your '
          'password to re-enable fingerprint unlock.');
    }
  }

  Future<void> _unlockWithBiometric() async {
    if (_bioPromptInFlight || _isLoading) return;
    setState(() {
      _bioPromptInFlight = true;
      _bioNotice = null;
    });
    try {
      final ok = await KeyManagerService().unlockWithBiometric();
      if (ok && mounted) await _routeAfterUnlock();
    } on BiometricInvalidatedException catch (e) {
      if (mounted) {
        setState(() {
          _bioAvailable = false;
          _bioNotice = e.toString();
        });
      }
    } on PublicKeyMismatchException {
      if (mounted) {
        setState(() => _error =
            'Vault key integrity check failed. Do not sync. Reinstall and '
            'restore from your recovery phrase.');
      }
    } on BiometricUnlockException catch (e) {
      if (!mounted) return;
      switch (e.code) {
        case BiometricUnlockError.userCanceled:
          break; // fell through to password on purpose — stay quiet
        case BiometricUnlockError.lockout:
        case BiometricUnlockError.lockoutPermanent:
          setState(() =>
              _bioNotice = 'Too many attempts — use your password.');
        default:
          setState(() =>
              _bioNotice = 'Fingerprint unavailable — use your password.');
      }
    } catch (e) {
      // Whatever goes wrong, the user must never be stranded on a silent
      // login screen — surface it and keep the password path front and
      // center. (This caught a real one: zeroing the codec's unmodifiable
      // seed buffer threw an Error no typed clause matched.)
      debugPrint('Biometric unlock failed unexpectedly: $e');
      if (mounted) {
        setState(() =>
            _bioNotice = 'Fingerprint unavailable — use your password.');
      }
    } finally {
      if (mounted) setState(() => _bioPromptInFlight = false);
    }
  }

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
    // Vault is unlocked — start the inactivity countdown.
    AppLockService().recordActivity();
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
    // Reconnect is for a vault that HAD a cloud and lost the session. If no
    // account was EVER registered, this is a signup interrupted at the
    // cloud picker (e.g. auto-locked while deciding) — reconnect is a dead
    // end there ("reconnect your cloud" for a cloud that never existed),
    // and the user is wedged. Resume the signup's cloud selection instead.
    final route = hasActive
        ? AppRoutes.home
        : AccountRegistry().hasAnyAccount
            ? AppRoutes.reconnect
            : AppRoutes.cloudSelection;
    Navigator.pushReplacementNamed(context, route);
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
              if (_bioAvailable) ...[
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: _bioPromptInFlight ? null : _unlockWithBiometric,
                  icon: ThemeIcon('fingerprint', color: cs.primary),
                  label: const Text('Use fingerprint'),
                ),
              ],
              if (_bioNotice != null) ...[
                const SizedBox(height: 12),
                Text(
                  _bioNotice!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: cs.onSurface.withAlpha(160),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}