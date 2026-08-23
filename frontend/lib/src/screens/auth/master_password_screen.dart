import 'package:flutter/material.dart';

import '../../../services/cnest_errors.dart';
import '../../../services/key_manager_service.dart';
import '../../config/routes.dart';
import '../../widgets/friendly_error_sheet.dart';
import '../../widgets/master_password_field_group.dart';
import '../../widgets/theme_icon.dart';
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
          Navigator.pushNamedAndRemoveUntil(
            context,
            AppRoutes.cloudSelection,
            // Clear the whole stack deliberately (the old splash-predicate
            // never matched — splash pushReplacement'd itself away).
            (route) => false,
            arguments: CloudSelectionArgs.restore,
          );
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

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    final isRestore = _mode == MasterPasswordMode.restore;
    final heading = isRestore
        ? 'Set a new master password.'
        : 'Create your master password.';
    final sub = isRestore
        ? 'Pick a new local password for this device. Next you connect your cloud, and we check the phrase against your vault before anything is saved.'
        : 'The recovery phrase owns the vault. This password unlocks it on this device. Forget the password, use the phrase to set a new one. Lose both, and the files are gone.';
    final ctaText =
        isRestore ? 'Restore vault' : 'Continue to recovery phrase';

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        leading: Navigator.canPop(context)
            ? IconButton(
                icon: const ThemeIcon('arrowLeft'),
                onPressed: () => Navigator.pop(context),
              )
            : null,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  heading,
                  style: textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
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
                if (!isRestore) ...[
                  const SizedBox(height: 12),
                  // The escape hatch lives where the user's mental model is:
                  // they're making a new vault and realize they already hold
                  // a phrase (new provider, existing key — or plain restore).
                  Center(
                    child: TextButton(
                      onPressed: _isLoading
                          ? null
                          : () => Navigator.pushReplacementNamed(
                              context, AppRoutes.restore),
                      child:
                          const Text('Use a recovery phrase I already have'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
