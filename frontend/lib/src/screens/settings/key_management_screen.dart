import 'package:flutter/material.dart';
import '../../widgets/theme_icon.dart';
import '../../../services/cloud/cloud_service.dart';

class KeyManagementScreen extends StatefulWidget {
  const KeyManagementScreen({super.key});

  @override
  State<KeyManagementScreen> createState() => _KeyManagementScreenState();
}

class _KeyManagementScreenState extends State<KeyManagementScreen> {
  bool _isTesting = false;
  String? _testResult;
  Color _resultColor = Colors.grey;

  Future<void> _runCanaryTest() async {
    setState(() {
      _isTesting = true;
      _testResult = "Running cryptographic handshake...";
      _resultColor = Colors.yellow;
    });

    // Run the actual test from CloudService
    final success = await CloudService().canaryTest();

    if (!mounted) return;

    setState(() {
      _isTesting = false;
      if (success) {
        _testResult = "INTEGRITY CONFIRMED\nAES-256-GCM Keys Active\nCloud Link Established";
        _resultColor = Colors.greenAccent;
      } else {
        _testResult = "INTEGRITY CHECK FAILED\nCould not verify encryption keys or connection.";
        _resultColor = Colors.redAccent;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Security Center')),
      body: Padding(
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
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _resultColor),
              ),
              child: Column(
                children: [
                  Icon(
                    _resultColor == Colors.greenAccent ? themeIconData('lock') : themeIconData('clock'),
                    size: 48,
                    color: _resultColor,
                  ),
                  const SizedBox(height: 16),
                  _isTesting
                      ? const CircularProgressIndicator()
                      : Text(
                          _testResult ?? "System Ready. Run test to verify keys.",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _resultColor,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'Courier', // Cyber feel
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
              "• Algorithm: AES-256-GCM\n• Key Storage: Android Keystore / iOS Keychain\n• Protocol: Google Drive AppData Scope",
              style: TextStyle(color: cs.onSurface.withAlpha(140), height: 1.5, fontFamily: 'Courier'),
            ),
          ],
        ),
      ),
    );
  }
}