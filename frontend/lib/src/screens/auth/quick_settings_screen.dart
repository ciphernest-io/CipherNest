import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/auto_sync_worker.dart';
import '../../../services/key_manager_service.dart';
import '../../config/routes.dart';
import '../../widgets/theme_icon.dart';

/// One-time convenience screen shown after successful signup or restore,
/// before the home screen. Lets the user opt into biometric unlock and
/// background auto-sync without having to hunt for them in Settings.
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
  static const _kBiometricEnabled = 'biometric_enabled_v1';
  // Watermark is the "only sync photos taken after this moment" cutoff.
  // Written when auto-sync is first enabled so we don't silently vault a
  // decade of gallery history — Migration handles that on demand.
  static const _kAutoSyncWatermark = 'auto_sync_watermark';
  static const _kShownFlag = 'quick_settings_shown_v1';

  bool? _canBiometric;
  bool _biometricOn = false;
  bool _autoSyncOn = false;
  bool _isEnrollingBiometric = false;

  @override
  void initState() {
    super.initState();
    KeyManagerService().canCheckBiometrics.then((v) {
      if (!mounted) return;
      setState(() => _canBiometric = v);
    });
  }

  Future<void> _toggleBiometric(bool wants) async {
    if (!wants) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kBiometricEnabled, false);
      if (!mounted) return;
      setState(() => _biometricOn = false);
      return;
    }

    setState(() => _isEnrollingBiometric = true);
    try {
      final auth = LocalAuthentication();
      final ok = await auth.authenticate(
        localizedReason: 'Set up CipherNest unlock',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
      if (!mounted) return;
      if (ok) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_kBiometricEnabled, true);
        if (mounted) setState(() => _biometricOn = true);
      } else {
        // User cancelled the biometric prompt. Leave toggle off.
        setState(() => _biometricOn = false);
      }
    } catch (e) {
      debugPrint('Biometric enroll failed: $e');
      if (mounted) setState(() => _biometricOn = false);
    } finally {
      if (mounted) setState(() => _isEnrollingBiometric = false);
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
      // Older photos need to be pulled in via the Migration screen.
      await prefs.setInt(
        _kAutoSyncWatermark,
        DateTime.now().millisecondsSinceEpoch,
      );
    }
    if (!mounted) return;
    setState(() => _autoSyncOn = v);
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
    final biometricAvailable = _canBiometric == true;

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
                'Two quick settings.',
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
              if (biometricAvailable)
                _SettingRow(
                  icon: 'fingerprint',
                  title: 'Unlock with fingerprint or face',
                  subtitle:
                      'Unlock with a tap instead of typing the password each time. The password stays as a fallback.',
                  value: _biometricOn,
                  isLoading: _isEnrollingBiometric,
                  onChanged: _toggleBiometric,
                ),
              if (biometricAvailable) const SizedBox(height: 12),
              _SettingRow(
                icon: 'arrowsClockwise',
                title: 'Auto-sync new photos in the background',
                subtitle:
                    "We'll only sync photos taken after today. To pull in old photos, use Migration in Settings later.",
                value: _autoSyncOn,
                onChanged: _toggleAutoSync,
              ),
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
    this.isLoading = false,
  });

  final String icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
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
          isLoading
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Switch(
                  value: value,
                  onChanged: isLoading ? null : onChanged,
                ),
        ],
      ),
    );
  }
}
