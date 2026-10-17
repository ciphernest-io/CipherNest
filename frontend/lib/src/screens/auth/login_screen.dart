import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../widgets/theme_icon.dart';
import '../../config/routes.dart';
import '../cloud_selection/cloud_selection_screen.dart' show CloudSelectionArgs;
import '../subscription/subscription_screen.dart' show SubscriptionScreenArgs;
import '../../config/billing.dart';
import '../../config/flags.dart';
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
    _openPasswordlessOrArmBiometric();
  }

  /// A vault created with "Continue without password" has nothing to ask for,
  /// so this screen must not sit in the way. Open it and move straight on
  /// through the SAME post-unlock routing the password path uses, so the
  /// reconnect case still behaves. Biometric is never offered in this mode:
  /// there is no password to fall back to when the key dies on an enrollment
  /// change, so arming one would be a trap.
  Future<void> _openPasswordlessOrArmBiometric() async {
    if (await KeyManagerService().isPasswordless()) {
      final ok = await KeyManagerService().unlockWithoutPassword();
      if (!mounted) return;
      if (ok) {
        await _routeAfterUnlock();
        return;
      }
      // Secure storage lost the seed (restored backup, OEM wipe). The phrase
      // is the only way back, and saying so beats an unexplained dead screen.
      setState(() => _bioNotice =
          'This vault could not be opened on this device. Restore it with '
          'your recovery phrase.');
      return;
    }
    await _initBiometric();
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
              _bioNotice = 'Too many attempts. Use your password.');
        default:
          setState(() =>
              _bioNotice = 'Fingerprint unavailable. Use your password.');
      }
    } catch (e) {
      // Whatever goes wrong, the user must never be stranded on a silent
      // login screen — surface it and keep the password path front and
      // center. (This caught a real one: zeroing the codec's unmodifiable
      // seed buffer threw an Error no typed clause matched.)
      debugPrint('Biometric unlock failed unexpectedly: $e');
      if (mounted) {
        setState(() =>
            _bioNotice = 'Fingerprint unavailable. Use your password.');
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
    } on UnlockThrottledException catch (e) {
      setState(() => _error = e.toString());
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

  /// After a successful unlock, decide where to land: home if an active
  /// cloud account is registered, reconnect if one was ever registered,
  /// else the signup's cloud selection. (A kill between the password and
  /// the phrase test never reaches here: the splash wipes that vault and
  /// restarts onboarding.)
  Future<void> _routeAfterUnlock() async {
    // Vault is unlocked — start the inactivity countdown.
    AppLockService().recordActivity();

    if (!mounted) return;
    final hasActive = AccountRegistry().activeAccount != null;
    // Resume-by-progress. Reconnect is for a vault that HAD a cloud and
    // lost the session. If no account was EVER registered, this is a signup
    // interrupted at the cloud picker (e.g. killed while deciding) —
    // reconnect is a dead end there, resume the signup's cloud selection.
    // An active account with the quick-settings step unfinished (a lock or
    // kill on that screen) resumes THERE — the step used to be silently
    // lost forever.
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    if (hasActive) {
      final settled = prefs.getBool('quick_settings_shown_v1') ?? false;
      Navigator.pushReplacementNamed(
          context, settled ? AppRoutes.home : AppRoutes.quickSettings);
      return;
    }
    // A kill on the signup paywall comes back to the paywall. Before this,
    // the step was skipped and the user landed on the provider picker.
    if (kPaywallEnabled &&
        !AccountRegistry().hasAnyAccount &&
        prefs.getString(kPaywallPendingPrefKey) == 'signup') {
      Navigator.pushReplacementNamed(
        context,
        AppRoutes.subscription,
        arguments: const SubscriptionScreenArgs(
          nextRoute: AppRoutes.cloudSelection,
        ),
      );
      return;
    }
    // Both cases are the provider picker. "Reconnect" was a separate
    // interstitial that only renamed the same choice.
    Navigator.pushReplacementNamed(
      context,
      AppRoutes.cloudSelection,
      arguments: AccountRegistry().hasAnyAccount
          ? CloudSelectionArgs.reconnect
          : CloudSelectionArgs.signup,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Centered while it fits; scrolls once the keyboard (or a landscape
    // viewport) leaves less than the ~383dp the column needs. The
    // minHeight + IntrinsicHeight pair keeps the centering identical
    // whenever there is room.
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - 48,
              ),
              child: IntrinsicHeight(
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
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
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
          ),
        ),
      ),
    );
  }
}