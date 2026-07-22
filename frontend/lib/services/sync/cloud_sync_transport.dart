import 'package:flutter/foundation.dart';

import '../cloud/account_registry.dart';
import '../cloud/cloud_service.dart';
import 'sync_engine.dart';

/// Production [SyncTransport]: the active cloud account's backup/log/.
///
/// When [accountId] is set, every call verifies that account is still the
/// active one and throws otherwise. CloudService resolves its provider from
/// the ACTIVE account at each call, so without this pin an account switch
/// mid-cycle could upload one account's op segments into another account's
/// log (and mark them pushed, losing them for the right account). The check
/// and the provider resolution are both synchronous at call start, so there
/// is no gap for a switch to slip through. A throw is safe at every point:
/// pushPending marks ops non-pending only after a durable upload, and
/// pullAndMerge commits per segment — the next cycle simply retries under
/// the right account.
class CloudSyncTransport implements SyncTransport {
  CloudSyncTransport({this.accountId});

  final String? accountId;

  T _pinned<T>(T Function() run) {
    if (accountId != null &&
        AccountRegistry().activeAccount?.id != accountId) {
      throw StateError(
          'Active account changed mid-sync (cycle pinned to $accountId)');
    }
    return run();
  }

  @override
  Future<List<Map<String, dynamic>>> listLogObjects() =>
      _pinned(() => CloudService().listLogObjects());

  @override
  Future<Uint8List> downloadObject(String cloudId) =>
      _pinned(() => CloudService().downloadFile(cloudId));

  @override
  Future<void> uploadLogObject({
    required String name,
    required Uint8List bytes,
  }) async {
    await _pinned(() => CloudService().uploadLogObject(name: name, bytes: bytes));
  }

  @override
  Future<void> deleteObject(String cloudId) =>
      _pinned(() => CloudService().deleteFile(cloudId));
}
