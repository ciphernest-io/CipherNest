import 'package:flutter/foundation.dart';

import '../cloud/account_registry.dart';
import 'cloud_sync_transport.dart';
import 'sync_engine.dart';
import 'sync_op.dart';

/// Entry point the rest of the app talks to: holds one [SyncEngine] per
/// active account and shields UI flows from sync failures — recording an
/// op or running a cycle must never break a rename, a delete, or an
/// upload. A failed record is retried implicitly: ops are minted from user
/// actions, and the pending queue is SQLite, so the only unrecoverable
/// case is "no active account", where there is nothing to sync anyway.
class SyncCoordinator {
  static final SyncCoordinator _instance = SyncCoordinator._();
  factory SyncCoordinator() => _instance;
  SyncCoordinator._();

  SyncEngine? _engine;
  String? _engineAccountId;

  /// The engine for the active account, or null when signed out.
  SyncEngine? get engine {
    final account = AccountRegistry().activeAccount;
    if (account == null) return null;
    if (_engine == null || _engineAccountId != account.id) {
      _engine = SyncEngine(
        transport: CloudSyncTransport(),
        accountId: account.id,
      );
      _engineAccountId = account.id;
    }
    return _engine;
  }

  /// Records a user action as an op. Never throws into the calling flow.
  Future<void> record(
    SyncOpKind kind,
    String targetId, {
    String? name,
    String? folderId,
    bool? favorite,
  }) async {
    try {
      await engine?.recordLocalOp(LocalSyncAction(
        kind: kind,
        targetId: targetId,
        name: name,
        folderId: folderId,
        favorite: favorite,
      ));
    } catch (e) {
      debugPrint('SyncCoordinator.record($kind, $targetId) failed: $e');
    }
  }

  /// Full cycle: push + pull + re-materialize. Requires unlocked vault.
  Future<void> sync() async {
    try {
      await engine?.syncCycle();
    } catch (e) {
      debugPrint('SyncCoordinator.sync failed: $e');
    }
  }

  /// Push-only — safe from locked/background contexts (sealing is
  /// public-key-only; nothing is decrypted).
  Future<void> pushOnly() async {
    try {
      await engine?.pushPending();
    } catch (e) {
      debugPrint('SyncCoordinator.pushOnly failed: $e');
    }
  }
}
