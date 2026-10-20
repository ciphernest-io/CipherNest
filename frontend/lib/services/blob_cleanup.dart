import 'package:flutter/foundation.dart';

import 'cloud/cloud_account.dart';
import 'cloud/cloud_service.dart';
import 'sync/sync_coordinator.dart';
import 'sync/sync_op.dart';

/// Blobs that landed for an upload attempt that still failed are deleted on
/// the spot, so no orphan is left for reconcile to adopt as a rootless file
/// with no local path. If the provider refuses the delete, a purgeFile op
/// condemns the file id: reconcile on every device skips the blob and the
/// sync cycle's condemned sweep retries the deletion until it lands.
///
/// Shared by the manual pipeline, auto-sync and the backfill. [account]
/// pins the provider for a batch bound to one account; null uses the
/// active one.
Future<void> discardLandedBlobs({
  required String fileId,
  String? mainCloudId,
  String? thumbCloudId,
  CloudAccount? account,
}) async {
  if (mainCloudId == null && thumbCloudId == null) return;
  var allGone = true;
  for (final id in [mainCloudId, thumbCloudId]) {
    if (id == null) continue;
    try {
      if (account != null) {
        await CloudService().providerFor(account).deleteFile(id);
      } else {
        await CloudService().deleteFile(id);
      }
    } catch (e) {
      allGone = false;
      debugPrint('Discard of landed blob $id failed: $e');
    }
  }
  if (allGone) return;
  try {
    await SyncCoordinator().record(SyncOpKind.purgeFile, fileId);
  } catch (e) {
    debugPrint('Could not condemn $fileId: $e');
  }
}
