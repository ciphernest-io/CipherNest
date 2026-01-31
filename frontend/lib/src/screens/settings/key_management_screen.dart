import 'package:flutter/material.dart';
import '../../config/theme.dart';
import '../../../services/drive_service.dart';

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

    // Run the actual test from DriveService
    final success = await DriveService.canaryTest();

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
    return Scaffold(
      appBar: AppBar(title: const Text('Security Center')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Encryption Status",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _resultColor),
              ),
              child: Column(
                children: [
                  Icon(
                    _resultColor == Colors.greenAccent ? Icons.lock : Icons.lock_clock,
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
                icon: const Icon(Icons.health_and_safety),
                label: const Text("Run Integrity Check"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              "Technical Details:",
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 8),
            const Text(
              "• Algorithm: AES-256-GCM\n• Key Storage: Android Keystore / iOS Keychain\n• Protocol: Google Drive AppData Scope",
              style: TextStyle(color: Colors.white54, height: 1.5, fontFamily: 'Courier'),
            ),
          ],
        ),
      ),
    );
  }
}