import 'package:flutter/material.dart';

import '../../../services/cnest_errors.dart';
import '../../../services/key_manager_service.dart';
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

  Future<void> _submit() async {
    if (!_isValid || _isLoading) return;
    setState(() => _isLoading = true);
    try {
      switch (_mode) {
        case MasterPasswordMode.createNew:
          final mnemonic =
              await KeyManagerService().createAccount(_password);
          if (!mounted) return;
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
          // Paywall slot (Aug 31 ruling): this password step follows the
          // phrase entry, so moving ahead passes the paywall. The whole
          // stack clears either way.
          if (kPaywallEnabled) {
            Navigator.pushNamedAndRemoveUntil(
              context,
              AppRoutes.subscription,
              (route) => false,
              arguments: const SubscriptionScreenArgs(
                nextRoute: AppRoutes.cloudSelection,
                nextArguments: CloudSelectionArgs.restore,
              ),
            );
          } else {
            Navigator.pushNamedAndRemoveUntil(
              context,
              AppRoutes.cloudSelection,
              (route) => false,
              arguments: CloudSelectionArgs.restore,
            );
          }
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
    final heading = isRestore
        ? 'Set a new master password'
        : 'Create your master password';
    final sub = isRestore
        ? 'A new local password for this device. Next you connect your cloud, and we check the phrase against your vault before anything is saved.'
        : 'This password only locks CipherNest on this device. It is not your encryption key; that is the recovery phrase you get next.';
    final ctaText =
        isRestore ? 'Restore vault' : 'Continue to recovery phrase';

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
        title: Text(
          heading,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.titleLarge,
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
