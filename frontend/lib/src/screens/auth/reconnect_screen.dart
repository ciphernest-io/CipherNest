import 'package:flutter/material.dart';

import '../../../services/cloud/account_registry.dart';
import '../../../services/cloud/cloud_account.dart';
import '../../config/routes.dart';
import '../../widgets/theme_icon.dart';
import '../cloud_selection/cloud_selection_screen.dart'
    show CloudSelectionArgs;

/// Shown when the master key is present on this device but the account
/// registry has no active cloud account (e.g. tokens invalidated, secure
/// storage bounced, user signed out from Settings). Reads the last provider
/// the user connected so the primary button can name it precisely.
class ReconnectScreen extends StatefulWidget {
  const ReconnectScreen({super.key});

  @override
  State<ReconnectScreen> createState() => _ReconnectScreenState();
}

class _ReconnectScreenState extends State<ReconnectScreen> {
  int? _lastProviderType;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    AccountRegistry().getLastProviderType().then((type) {
      if (!mounted) return;
      setState(() {
        _lastProviderType = type;
        _loaded = true;
      });
    });
  }

  String _providerDisplayName(int? type) {
    switch (type) {
      case CloudAccount.providerGoogle:
        return 'Google Drive';
      case CloudAccount.providerOneDrive:
        return 'OneDrive';
      case CloudAccount.providerDropbox:
        return 'Dropbox';
      default:
        return 'cloud';
    }
  }

  void _reconnect() {
    // For launch we send the user through the standard picker. In a future
    // slice we'd auto-invoke the last provider's OAuth flow and skip the
    // picker; keeping it manual is one extra tap and zero code duplication.
    Navigator.pushReplacementNamed(
      context,
      AppRoutes.cloudSelection,
      arguments: CloudSelectionArgs.reconnect,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final providerName = _providerDisplayName(_lastProviderType);
    final primaryLabel = _lastProviderType == null
        ? 'Reconnect cloud'
        : 'Reconnect $providerName';

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          child: Column(
            children: [
              const Spacer(),
              ThemeIcon('cloudSlash', size: 64, color: cs.primary),
              const SizedBox(height: 20),
              Text(
                'Reconnect your cloud.',
                style: text.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                "You're in, but your cloud isn't. Your files are safe on your Drive or OneDrive; this phone just needs to link back up. Happens sometimes.",
                style: text.bodyMedium?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.72),
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loaded ? _reconnect : null,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: Text(
                    primaryLabel,
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
    );
  }
}
