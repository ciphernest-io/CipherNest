import 'package:flutter/material.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';
import '../../../services/cloud/canary_retry.dart';

/// Outcome of the canary integrity check. The display color is derived from
/// this in build() via theme tokens — never stored as a raw Color.
enum _KeyCheckStatus { idle, checking, ok, warn, error }

class KeyManagementScreen extends StatefulWidget {
  const KeyManagementScreen({super.key});

  @override
  State<KeyManagementScreen> createState() => _KeyManagementScreenState();
}

class _KeyManagementScreenState extends State<KeyManagementScreen> {
  bool _isTesting = false;
  String? _testResult;
  _KeyCheckStatus _status = _KeyCheckStatus.idle;

  Future<void> _runCanaryTest() async {
    setState(() {
      _isTesting = true;
      _testResult = "Running cryptographic handshake...";
      _status = _KeyCheckStatus.checking;
    });

    // The shared helper retries once on transient (network / OAuth warm-up)
    // failures. A `false` return is a real crypto mismatch — wrong key.
    // A rethrown exception is a real network/auth error after retry.
    bool success = false;
    Object? transientError;
    try {
      success = await canaryWithRetry();
    } catch (e) {
      transientError = e;
    }

    if (!mounted) return;

    setState(() {
      _isTesting = false;
      if (success) {
        _testResult =
            "INTEGRITY CONFIRMED\nAES-256-GCM Keys Active\nCloud Link Established";
        _status = _KeyCheckStatus.ok;
      } else if (transientError != null) {
        _testResult =
            "COULD NOT REACH CLOUD\nCheck your connection and try again.\n\n${transientError.toString()}";
        _status = _KeyCheckStatus.warn;
      } else {
        _testResult =
            "INTEGRITY CHECK FAILED\nCould not decrypt the canary file. "
            "Either the master key on this device does not match the vault, "
            "or the cloud files were modified outside CipherNest.";
        _status = _KeyCheckStatus.error;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    final resultColor = switch (_status) {
      _KeyCheckStatus.idle => t.fgMuted,
      _KeyCheckStatus.checking => t.warning,
      _KeyCheckStatus.ok => t.success,
      _KeyCheckStatus.warn => t.warning,
      _KeyCheckStatus.error => t.danger,
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Key Management')),
      // Scroll view instead of Padding: a no-op while the content fits, so a
      // long error result no longer overflows on short or landscape screens.
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Encryption Status",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: cs.onSurface),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(t.rCard),
                border: Border.all(color: resultColor),
              ),
              child: Column(
                children: [
                  ThemeIcon(
                    _status == _KeyCheckStatus.ok ? 'lock' : 'clock',
                    size: 48,
                    color: resultColor,
                  ),
                  const SizedBox(height: 16),
                  _isTesting
                      ? const CircularProgressIndicator()
                      : Text(
                          _testResult ?? "System Ready. Run test to verify keys.",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: resultColor,
                            fontWeight: FontWeight.w600,
                            fontFamily: t.monoFontFamily, // Cyber feel
                          ),
                        ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _isTesting ? null : _runCanaryTest,
                icon: ThemeIcon('shieldCheck'),
                label: const Text("Run Integrity Check"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: cs.onPrimary,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              "Technical Details:",
              style: TextStyle(color: cs.onSurface.withAlpha(120)),
            ),
            const SizedBox(height: 8),
            Text(
              "• Algorithm: AES-256-GCM\n• Key storage: Android Keystore\n• Cloud: your connected drive",
              style: TextStyle(color: cs.onSurface.withAlpha(140), height: 1.5, fontFamily: t.monoFontFamily),
            ),
          ],
        ),
      ),
    );
  }
}