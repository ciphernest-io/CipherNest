import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/cnest_errors.dart';
import '../../../services/billing_service.dart';
import '../../../services/key_manager_service.dart';
import '../../../services/subscription_service.dart';
import '../../config/flags.dart';
import '../../config/routes.dart';
import '../../widgets/friendly_error_sheet.dart';
import '../../widgets/master_password_field_group.dart';
import '../../widgets/theme_icon.dart';
import '../subscription/subscription_screen.dart'
    show SubscriptionScreenArgs;
import '../cloud_selection/cloud_selection_screen.dart' show CloudSelectionArgs;

/// Which flow entered the master-password screen.
///
/// [createNew] is the signup path: generates a fresh vault via
/// [KeyManagerService.createAccount] and hands the mnemonic to the
/// recovery-phrase screen for display + type-back challenge.
///
/// [restore] is the recovery path: the caller has a checksum-valid mnemonic
/// (passed via [MasterPasswordArgs.mnemonic]); this screen STAGES it via
/// [KeyManagerService.stageRecovery] — nothing is persisted until the cloud
/// canary proves the phrase owns the vault (a wrong-but-valid phrase used
/// to permanently overwrite the seed here, before any ownership check).
enum MasterPasswordMode { createNew, restore }

/// Route argument carrier. Missing argument (or wrong type) is treated as
/// [createNew] so old call sites keep working.
class MasterPasswordArgs {
  const MasterPasswordArgs({
    this.mode = MasterPasswordMode.createNew,
    this.mnemonic,
  });

  final MasterPasswordMode mode;
  final String? mnemonic;

  static const createNew = MasterPasswordArgs();
}

/// Master-password entry, shared between signup step 1 and the second half
/// of the restore flow. Same rules + meter + eye toggles either way; only
/// the copy and the submit action differ.
class MasterPasswordScreen extends StatefulWidget {
  const MasterPasswordScreen({
    super.key,
    this.args = MasterPasswordArgs.createNew,
  });

  final MasterPasswordArgs args;

  @override
  State<MasterPasswordScreen> createState() => _MasterPasswordScreenState();
}

class _MasterPasswordScreenState extends State<MasterPasswordScreen> {
  String _password = '';
  bool _isValid = false;
  bool _isLoading = false;

  MasterPasswordMode get _mode => widget.args.mode;

  /// Set once this screen has handed off forward, so dispose does not drop
  /// keys the next screen is about to use.
  bool _movedForward = false;

  @override
  void initState() {
    super.initState();
    if (_mode == MasterPasswordMode.restore) _stageEarly();
  }

  /// Restore stages the recovery the moment the screen opens, not on submit.
  /// Staging persists nothing, but it derives the keys, and with them the
  /// seed-derived billing ID. That lets the entitlement check and the
  /// offering fetch run while the user is still typing: someone who already
  /// owns Plus skips the paywall outright, and everyone else reaches it with
  /// the prices already cached.
  Future<void> _stageEarly() async {
    final mnemonic = widget.args.mnemonic;
    if (mnemonic == null || mnemonic.isEmpty) return;
    try {
      await KeyManagerService().stageRecovery(mnemonic);
    } catch (_) {
      return; // the submit path reports a bad phrase properly
    }
    if (!kPaywallEnabled) return;
    unawaited(BillingService().refreshEntitlement());
    unawaited(BillingService().offerings());
  }

  @override
  void dispose() {
    // Backing out of a restore must not leave keys for a vault that was
    // never committed resident in memory.
    if (_mode == MasterPasswordMode.restore && !_movedForward) {
      KeyManagerService().discardStagedRecovery();
    }
    super.dispose();
  }

  /// Next step after a restore is staged, with or without a password. A
  /// phrase that already owns Plus is never shown the paywall. The whole
  /// stack clears either way; cloud selection runs the ownership canary and
  /// commits.
  void _advanceFromRestore() {
    _movedForward = true;
    final showPaywall = kPaywallEnabled && !SubscriptionService().isPlus;
    if (showPaywall) {
      Navigator.pushNamedAndRemoveUntil(
        context,
        AppRoutes.subscription,
        (route) => false,
        arguments: const SubscriptionScreenArgs(
          nextRoute: AppRoutes.cloudSelection,
          nextArguments: CloudSelectionArgs.restore,
        ),
      );
      return;
    }
    Navigator.pushNamedAndRemoveUntil(
      context,
      AppRoutes.cloudSelection,
      (route) => false,
      arguments: CloudSelectionArgs.restore,
    );
  }

  /// No app password, in either mode. On signup the seed goes to the
  /// Keystore-backed secure store; on restore the staged recovery is
  /// committed the same way once the canary passes. The recovery phrase is
  /// still the root of trust, so nothing about a second device changes.
  Future<void> _continueWithoutPassword() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      if (_mode == MasterPasswordMode.restore) {
        final mnemonic = widget.args.mnemonic;
        if (mnemonic == null || mnemonic.isEmpty) {
          throw StateError(
            'MasterPasswordScreen entered restore mode without a mnemonic',
          );
        }
        await KeyManagerService().stageRecovery(mnemonic);
        if (!mounted) return;
        _advanceFromRestore();
        return;
      }
      final mnemonic =
          await KeyManagerService().createAccountWithoutPassword();
      if (!mounted) return;
      _movedForward = true;
      Navigator.pushReplacementNamed(
        context,
        AppRoutes.recoveryPhrase,
        arguments: mnemonic,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not continue.')),
      );
    }
  }

  Future<void> _submit() async {
    if (!_isValid || _isLoading) return;
    setState(() => _isLoading = true);
    try {
      switch (_mode) {
        case MasterPasswordMode.createNew:
          final mnemonic =
              await KeyManagerService().createAccount(_password);
          if (!mounted) return;
          _movedForward = true;
          Navigator.pushReplacementNamed(
            context,
            AppRoutes.recoveryPhrase,
            arguments: mnemonic,
          );
        case MasterPasswordMode.restore:
          final mnemonic = widget.args.mnemonic;
          if (mnemonic == null || mnemonic.isEmpty) {
            throw StateError(
              'MasterPasswordScreen entered restore mode without a mnemonic',
            );
          }
          await KeyManagerService().stageRecovery(mnemonic, _password);
          if (!mounted) return;
          _advanceFromRestore();
      }
    } catch (e, s) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      debugPrint('MasterPasswordScreen submit failed: $e\n$s');
      showCnestError(
        context,
        UnexpectedError(
          code: _mode == MasterPasswordMode.createNew ? 'MP_CREATE' : 'MP_RESTORE',
          debugDetail: e.toString(),
        ),
      );
    }
  }

  /// Signup has no back stack (onboarding cleared it), so back is an
  /// explicit return to slide 1; restore keeps the normal pop.
  void _back() {
    if (_mode == MasterPasswordMode.restore && Navigator.canPop(context)) {
      Navigator.pop(context);
      return;
    }
    Navigator.pushNamedAndRemoveUntil(
      context,
      AppRoutes.onboarding,
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    final isRestore = _mode == MasterPasswordMode.restore;
    const heading = 'Create your master password';
    final sub = isRestore
        ? 'This password only locks CipherNest on this device. It is not your encryption key; that is the recovery phrase you just entered.'
        : 'This password only locks CipherNest on this device. It is not your encryption key; that is the recovery phrase you get next.';
    final ctaText =
        isRestore ? 'Continue to vault' : 'Continue to recovery phrase';

    return Scaffold(
      // Title lives in the AppBar so it stays put while the body scrolls
      // under the keyboard.
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        centerTitle: true,
        leading: IconButton(
          icon: const ThemeIcon('arrowLeft'),
          onPressed: _isLoading ? null : _back,
        ),
        // Fixed copy, not user content, so it must never lose characters.
        // At 360dp with the OS font slider at 1.3x, "Create your master
        // password" ellipsised to "Create your master passwo...". scaleDown
        // shrinks only when it would otherwise be cut, so the default scale
        // is untouched. Album and file titles elsewhere keep plain ellipsis,
        // which is the right behaviour for names the user chose.
        title: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            heading,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.titleLarge,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  sub,
                  style: textTheme.bodyMedium?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.72),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 28),
                MasterPasswordFieldGroup(
                  onChanged: (password, isValid) {
                    _password = password;
                    if (isValid != _isValid) {
                      setState(() => _isValid = isValid);
                    }
                  },
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: (_isValid && !_isLoading) ? _submit : null,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            ctaText,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: _isLoading ? null : _continueWithoutPassword,
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.onSurface,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Text(
                  'Continue without password',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
