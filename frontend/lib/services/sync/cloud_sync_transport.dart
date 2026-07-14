import 'package:flutter/foundation.dart';

import '../cloud/cloud_service.dart';
import 'sync_engine.dart';

/// Production [SyncTransport]: the active cloud account's backup/log/.
class CloudSyncTransport implements SyncTransport {
  @override
  Future<List<Map<String, dynamic>>> listLogObjects() =>
      CloudService().listLogObjects();

  @override
  Future<Uint8List> downloadObject(String cloudId) =>
      CloudService().downloadFile(cloudId);

  @override
  Future<void> uploadLogObject({
    required String name,
    required Uint8List bytes,
  }) async {
    await CloudService().uploadLogObject(name: name, bytes: bytes);
  }
}
