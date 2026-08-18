import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/auto_sync_worker.dart';
import '../../../services/biometric_unlock_service.dart';
import '../../../services/key_manager_service.dart';
import '../../../services/notify.dart';
import '../../config/routes.dart';
import '../../config/theme_controller.dart';
import '../../widgets/password_confirm_dialog.dart';
import '../../widgets/theme_icon.dart';
import '../settings/backup_albums_screen.dart';

/// One-time convenience screen shown after successful signup or restore,
/// before the home screen. Lets the user opt into background auto-sync
/// without having to hunt for it in Settings.
///
/// Gated by SharedPreferences 'quick_settings_shown_v1'. `cloudSelection`
/// routes here only when that flag is false and the mode is `signup` or
/// `restore`. Reconnect and add-another skip straight to home.
class QuickSettingsScreen extends StatefulWidget {
  const QuickSettingsScreen({super.key});

  @override
  State<QuickSettingsScreen> createState() => _QuickSettingsScreenState();
}

class _QuickSettingsScreenState extends State<QuickSettingsScreen> {
  // Watermark is the "only sync photos taken after this moment" cutoff.
  // Written when auto-sync is first enabled so we don't silently vault a
  // decade of gallery history — Migration handles that on demand.
  static const _kAutoSyncWatermark = 'auto_sync_watermark';
  static const _kShownFlag = 'quick_settings_shown_v1';

  bool _autoSyncOn = false;
  bool _bioOn = false;
  bool _bioOfferable = false;

  @override
  void initState() {
    super.initState();
    _probeBiometric();
  }

  Future<void> _probeBiometric() async {
    final capability = await BiometricUnlockService().capability();
    if (!mounted) return;
    setState(() =>
        _bioOfferable = capability == BiometricCapability.available);
  }

  /// Same invariant as Settings: the seed exists in memory only during a
  /// password entry, so arming asks for the password — even here, minutes
  /// after the user chose it. No signup special case.
  Future<void> _toggleBiometric(bool v) async {
    if (!v) {
      await KeyManagerService().disableBiometric();
      if (mounted) setState(() => _bioOn = false);
      return;
    }
    final password = await showPasswordConfirmDialog(
      context,
      message: 'Enter the master password you just created to set up '
          'fingerprint unlock.',
    );
    if (password == null || !mounted) return;
    try {
      final ok = await KeyManagerService().enableBiometric(password);
      if (!mounted) return;
      if (!ok) {
        Notify.error('Incorrect password');
        return;
      }
      setState(() => _bioOn = true);
    } on BiometricUnlockException catch (e) {
      if (e.code == BiometricUnlockError.userCanceled) return;
      Notify.error('Could not enable fingerprint unlock (${e.code.name})');
    }
  }

  Future<void> _toggleAutoSync(bool v) async {
    // Quick Settings defaults to `background` when the user opts in — it's
    // the "always on, minimal battery" pick most people expect when they
    // enable auto-sync. Settings later exposes the foreground-only pick
    // for anyone who wants the app-open-only cadence instead.
    final mode = v ? AutoSyncMode.background : AutoSyncMode.off;
    await AutoSyncScheduler.writeMode(mode);
    if (v) {
      final prefs = await SharedPreferences.getInstance();
      // Watermark = "now" so only photos taken after this moment auto-sync.
      // Per-album backfill (or Migration) pulls in older photos on demand.
      await prefs.setInt(
        _kAutoSyncWatermark,
        DateTime.now().millisecondsSinceEpoch,
      );
    }
    if (!mounted) return;
    setState(() => _autoSyncOn = v);
    // Which albums? All vs a checklist, with the include-existing shortcut.
    if (v) await showBackupAlbumChoiceSheet(context);
  }

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShownFlag, true);
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, AppRoutes.home);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _bioOfferable ? 'Two quick settings.' : 'One quick setting.',
                style: text.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                'You can change these anytime in Settings.',
                style: text.bodyMedium?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.72),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              _SettingRow(
                icon: 'arrowsClockwise',
                title: 'Auto-sync new photos in the background',
                subtitle:
                    "We'll only sync photos taken after today. To pull in old photos, use Migration in Settings later.",
                value: _autoSyncOn,
                onChanged: _toggleAutoSync,
              ),
              if (_bioOfferable) ...[
                const SizedBox(height: 12),
                _SettingRow(
                  icon: 'fingerprint',
                  title: 'Unlock with fingerprint',
                  subtitle:
                      'Hardware-backed fingerprint unlock on this device. '
                      'Your master password always works.',
                  value: _bioOn,
                  onChanged: _toggleBiometric,
                ),
              ],
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _finish,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text(
                    'Enter CipherNest',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _finish,
                child: Text(
                  'Skip for now',
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius:
            BorderRadius.circular(ThemeController().tokens.rCard),
        border: Border.all(color: cs.outline.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 12, top: 2),
            child: ThemeIcon(icon, size: 22, color: cs.primary, selected: true),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: text.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: text.bodySmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.7),
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
