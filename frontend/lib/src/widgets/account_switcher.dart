import 'package:flutter/material.dart';
import 'theme_icon.dart';
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
        return themeIconData('googleLogo');
      case CloudAccount.providerOneDrive:
        return themeIconData('microsoftOutlookLogo');
      case CloudAccount.providerDropbox:
        return themeIconData('dropboxLogo');
      default:
        return themeIconData('cloud');
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
      DatabaseService().setCurrentAccount(newActive.id);
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
                      ThemeIcon('check', selected: true,
                          size: 16, color: cs.primary),
                  ],
                ),
              ),
            const PopupMenuDivider(),
            PopupMenuItem<String>(
              value: '__add__',
              child: Row(
                children: [
                  ThemeIcon('plus',
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
                ThemeIcon('caretDown',
                    size: 14, color: cs.onSurface.withAlpha(140)),
              ],
            ),
          ),
        );
      },
    );
  }
}
