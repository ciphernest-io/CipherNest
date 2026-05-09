import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../config/routes.dart';
import '../../services/cloud/account_registry.dart';
import '../../services/cloud/cloud_account.dart';
import '../../services/cloud/cloud_service.dart';
import '../../services/database_service.dart';
import '../../services/sync_service.dart';

/// AppBar widget that shows the current active account and lets the user
/// quick-switch between connected accounts or add a new one.
/// Listens to AccountRegistry, so the UI rebuilds on any change.
class AccountSwitcher extends StatelessWidget {
  const AccountSwitcher({super.key});

  IconData _providerIcon(int providerType) {
    switch (providerType) {
      case CloudAccount.providerGoogle:
        return PhosphorIcons.googleLogo(PhosphorIconsStyle.thin);
      case CloudAccount.providerOneDrive:
        return PhosphorIcons.microsoftOutlookLogo(PhosphorIconsStyle.thin);
      case CloudAccount.providerDropbox:
        return PhosphorIcons.dropboxLogo(PhosphorIconsStyle.thin);
      default:
        return PhosphorIcons.cloud(PhosphorIconsStyle.thin);
    }
  }

  Future<void> _handleSelect(BuildContext context, String? value) async {
    if (value == null) return;
    if (value == '__add__') {
      await Navigator.pushNamed(
        context,
        AppRoutes.cloudSelection,
        arguments: true, // isAddAnother
      );
      return;
    }
    final active = AccountRegistry().activeAccount;
    if (active != null && active.id == value) return;

    await AccountRegistry().setActive(value);
    final newActive = AccountRegistry().activeAccount;
    if (newActive != null) {
      DatabaseService().setCurrentAccount(newActive.email);
      CloudService().reset();
      // Trigger a sync to load that account's files
      SyncService().syncNow(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: AccountRegistry(),
      builder: (context, _) {
        final active = AccountRegistry().activeAccount;
        final accounts = AccountRegistry().accounts;
        if (active == null) {
          return const SizedBox.shrink();
        }
        return PopupMenuButton<String>(
          tooltip: 'Switch account',
          offset: const Offset(0, 48),
          color: cs.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          onSelected: (val) => _handleSelect(context, val),
          itemBuilder: (ctx) => [
            for (final a in accounts)
              PopupMenuItem<String>(
                value: a.id,
                child: Row(
                  children: [
                    Icon(_providerIcon(a.providerType),
                        size: 20, color: cs.onSurface),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(a.email,
                              style: TextStyle(
                                  fontSize: 13,
                                  color: cs.onSurface,
                                  fontWeight: FontWeight.w500)),
                          Text(a.providerName,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurface.withAlpha(140))),
                        ],
                      ),
                    ),
                    if (a.id == active.id)
                      Icon(PhosphorIcons.check(PhosphorIconsStyle.fill),
                          size: 16, color: cs.primary),
                  ],
                ),
              ),
            const PopupMenuDivider(),
            PopupMenuItem<String>(
              value: '__add__',
              child: Row(
                children: [
                  Icon(PhosphorIcons.plus(PhosphorIconsStyle.thin),
                      size: 18, color: cs.primary),
                  const SizedBox(width: 12),
                  Text('Add another account',
                      style: TextStyle(color: cs.primary, fontSize: 13)),
                ],
              ),
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: cs.primary.withAlpha(60),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(_providerIcon(active.providerType),
                      size: 16, color: cs.primary),
                ),
                const SizedBox(width: 6),
                Icon(PhosphorIcons.caretDown(PhosphorIconsStyle.thin),
                    size: 14, color: cs.onSurface.withAlpha(140)),
              ],
            ),
          ),
        );
      },
    );
  }
}
