import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../../config/routes.dart';
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

  @override
  void initState() {
    super.initState();
    // REMOVED: _triggerBiometrics(); 
    // Now the user must explicitly tap the button.
  }

  Future<void> _triggerBiometrics() async {
    final success = await KeyManagerService().authenticateWithBiometrics();
    if (success && mounted) {
      Navigator.pushReplacementNamed(context, AppRoutes.home);
    }
  }

  Future<void> _loginWithPassword() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final success = await KeyManagerService().login(_passwordController.text);
      if (success && mounted) {
        Navigator.pushReplacementNamed(context, AppRoutes.home);
      } else {
        setState(() => _error = "Incorrect password");
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(PhosphorIcons.lockKey(PhosphorIconsStyle.thin), size: 80, color: cs.primary),
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
                  prefixIcon: Icon(PhosphorIcons.key(PhosphorIconsStyle.thin)),
                ),
              ),
              const SizedBox(height: 24),

              ElevatedButton(
                onPressed: _isLoading ? null : _loginWithPassword,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isLoading 
                  ? const CircularProgressIndicator() 
                  : const Text('Unlock Vault'),
              ),
              
              const SizedBox(height: 16),
              
              // This is now the primary way to trigger biometrics
              TextButton.icon(
                onPressed: _triggerBiometrics,
                icon: Icon(PhosphorIcons.fingerprint(PhosphorIconsStyle.thin)),
                label: const Text('Use Biometrics'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}