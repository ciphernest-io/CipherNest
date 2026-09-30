import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../cloud/account_registry.dart';
import 'cloud_sync_transport.dart';
import 'device_registry_service.dart';
import 'sync_engine.dart';
import 'sync_op.dart';

/// Once-only memory for undone-folder-move notices (op keys already shown).
const kNotifiedUndoneMovesPref = 'sync_notified_undone_moves_v1';

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

  /// Edit-vs-delete conflicts from the most recent sync, as ready-to-show
  /// messages. The UI (home screen) listens and shows a one-time notice.
  final ValueNotifier<List<String>> conflicts = ValueNotifier(const []);

  /// The engine for the active account, or null when signed out.
  SyncEngine? get engine {
    final account = AccountRegistry().activeAccount;
    if (account == null) return null;
    if (_engine == null || _engineAccountId != account.id) {
      _engine = SyncEngine(
        transport: CloudSyncTransport(accountId: account.id),
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
    String? hash,
    int? size,
    int? captured,
  }) async {
    try {
      await engine?.recordLocalOp(LocalSyncAction(
        kind: kind,
        targetId: targetId,
        name: name,
        folderId: folderId,
        favorite: favorite,
        hash: hash,
        size: size,
        captured: captured,
      ));
    } catch (e) {
      debugPrint('SyncCoordinator.record($kind, $targetId) failed: $e');
    }
  }

  /// Full cycle: register this device (once / on rename), push, pull,
  /// re-materialize. Requires unlocked vault.
  Future<void> sync() async {
    try {
      if (engine == null) return;
      await DeviceRegistryService().ensureRegistered();
      await engine!.syncCycle();
      await _surfaceConflicts();
    } catch (e) {
      debugPrint('SyncCoordinator.sync failed: $e');
    }
  }

  Future<void> _surfaceConflicts() async {
    final accountId = _engineAccountId;
    if (accountId == null) return;
    final messages = <String>[];

    final found = await engine!.detectConflicts();
    for (final c in found) {
      final who = await DeviceRegistryService()
          .nameFor(c.deleterDeviceId, accountId: accountId);
      if (c.isFolder) {
        messages.add(c.purged
            ? 'Folder "${c.fileName}" was permanently deleted on $who.'
            : 'You edited folder "${c.fileName}", but it was deleted on '
                '$who. It\'s in the Recycle Bin.');
      } else {
        messages.add(c.purged
            ? '"${c.fileName}" was permanently deleted on $who.'
            : 'You edited "${c.fileName}", but it was deleted on $who. '
                'It\'s in the Recycle Bin.');
      }
    }

    // Cycle-skipped folder moves of THIS device: told once per op, ever —
    // the skip is a permanent fact of the log, so without the persisted
    // dedup it would re-announce after every sync.
    try {
      final undone = await engine!.detectUndoneFolderMoves();
      if (undone.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        final seen =
            (prefs.getStringList(kNotifiedUndoneMovesPref) ?? []).toSet();
        var changed = false;
        for (final u in undone) {
          if (!seen.add(u.opKey)) continue;
          changed = true;
          final who = u.otherDeviceId == null
              ? 'another device'
              : await DeviceRegistryService()
                  .nameFor(u.otherDeviceId!, accountId: accountId);
          messages.add('Your move of folder "${u.folderName}" was undone. '
              'It conflicted with a folder move on $who.');
        }
        if (changed) {
          // Bounded: keep the most recent entries only.
          final list = seen.toList();
          await prefs.setStringList(
              kNotifiedUndoneMovesPref,
              list.length > 200
                  ? list.sublist(list.length - 200)
                  : list);
        }
      }
    } catch (e) {
      debugPrint('SyncCoordinator: undone-move surfacing failed: $e');
    }

    if (messages.isEmpty) return;
    conflicts.value = messages;
  }

  /// Clears surfaced conflicts once the UI has shown them.
  void clearConflicts() => conflicts.value = const [];

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
