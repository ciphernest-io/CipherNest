import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_lock_service.dart';
import 'audio_player_service.dart';
import 'auto_sync_worker.dart';
import 'cloud/account_registry.dart';
import 'cloud/cloud_service.dart';
import 'database_service.dart';
import 'key_manager_service.dart';

/// "Forget this vault on this device" — the full local reset the sign-out
/// menu never had (the old sign-out removed one OAuth token and left the
/// seed, biometrics, DB, and every flow flag behind; MTR#1 F4).
///
/// Scope: THIS DEVICE ONLY. Cloud blobs, the op-log, and snapshots are
/// untouched — the recovery phrase restores access here or anywhere.
class VaultResetService {
  static final VaultResetService _instance = VaultResetService._();
  factory VaultResetService() => _instance;
  VaultResetService._();

  /// Prefs that encode onboarding progress / per-vault state. Cosmetic
  /// device preferences (theme, size units, zoom level, auto-lock minutes)
  /// deliberately survive.
  static const List<String> _vaultPrefs = [
    'setup_completed_v1',
    'quick_settings_shown_v1',
    'multi_device_notice_shown_v1',
    'last_provider_type_v1',
    'auto_sync_mode',
    'auto_sync_enabled',
    'auto_sync_watermark',
    'auto_sync_last_run',
    'auto_sync_last_bg_run',
    'auto_sync_run_lease_v1',
    'auto_sync_interval_minutes',
    'auto_sync_interval_applied',
    'bg_sync_summary_v1',
    'backup_selection_mode',
    'backup_enrolled_buckets',
    'backup_pending_backfill',
    'sync_unreadable_segments_v1',
    'sync_notified_undone_moves_v1',
    // Vault-derived state that used to survive a reset (MASVS F-21).
    'auto_sync_deleted_keys',
    'sync_clock_skew_v1',
    'meta_migration_remaining_v1',
    'vault_meta_unreadable_v1',
    'paywall_pending_v1',
    'entitlement_plus_v1',
    'plus_expires_at_v1',
    'plus_is_lifetime_v1',
    'plus_last_verified_at_v1',
    'plus_ever_held_v1',
    'plus_product_v1',
    'plus_plan_v1',
    'unlock_failures_v1',
    'unlock_locked_until_v1',
  ];

  /// Tears the vault off this device. Ordering matters: stop the movers
  /// first, then keys, then state, then bytes on disk.
  Future<void> forgetVaultOnDevice() async {
    // 1. Stop anything that could write mid-wipe; auto-lock disarms back to
    // its pre-onboarding state.
    AppLockService().onVaultForgotten();
    try {
      await AudioPlayerService().stop();
    } catch (_) {}
    try {
      await AutoSyncScheduler.writeMode(AutoSyncMode.off);
    } catch (_) {}

    // 2. Provider OAuth session (best-effort; local wipe must not hinge on
    // the network) + registry.
    try {
      await CloudService().signOut();
    } catch (_) {}
    CloudService().reset();
    await AccountRegistry().clearAll();

    // 3. Keys: seed blob, public key, mnemonic blob, flags, biometric wrap.
    await KeyManagerService().wipeVault();

    // 4. Metadata DB (file is deleted; fresh schema on next open).
    try {
      await DatabaseService().destroyDatabase();
    } catch (e) {
      debugPrint('VaultResetService: DB destroy failed: $e');
    }

    // 5. Flow/state prefs.
    final prefs = await SharedPreferences.getInstance();
    for (final key in _vaultPrefs) {
      await prefs.remove(key);
    }

    // 6. Decrypted artifacts in the temp cache.
    try {
      final tempDir = await getTemporaryDirectory();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
        await tempDir.create();
      }
    } catch (e) {
      debugPrint('VaultResetService: cache wipe failed: $e');
    }
  }
}
