import 'package:flutter/material.dart';
import '../../config/routes.dart';
import '../../config/theme.dart';
import '../../../services/key_manager_service.dart';

class RestoreAccountScreen extends StatefulWidget {
  const RestoreAccountScreen({super.key});

  @override
  State<RestoreAccountScreen> createState() => _RestoreAccountScreenState();
}

class _RestoreAccountScreenState extends State<RestoreAccountScreen> {
  final _phraseController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;

  Future<void> _restore() async {
    final phrase = _phraseController.text.trim();
    final password = _passwordController.text;

    // Basic Validation
    if (phrase.split(' ').length != 12) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter exactly 12 words')),
      );
      return;
    }
    if (password.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password must be 8+ chars')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      // This recovers the Master Key from the words
      await KeyManagerService().recoverAccount(phrase, password);
      
      if (mounted) {
        // Go to Cloud Selection -> Home
        Navigator.pushNamedAndRemoveUntil(
          context, 
          AppRoutes.cloudSelection, 
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Restore Wallet')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Text(
              'Enter your 12-word recovery phrase to restore access to your encrypted files.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _phraseController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Recovery Phrase',
                hintText: 'apple river house ...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Set New Password',
                border: OutlineInputBorder(),
              ),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _restore,
                child: _isLoading ? const CircularProgressIndicator() : const Text('Restore Account'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}