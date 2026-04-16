import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';
import 'auto_sync_service.dart';

const String autoSyncTaskName = 'autoSyncTask';

/// Top-level callback dispatcher for WorkManager.
/// Must be a top-level function (not a method).
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != autoSyncTaskName) return true;

    try {
      final notifications = FlutterLocalNotificationsPlugin();
      await notifications.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );

      // Show "syncing" notification
      await _showNotification(
        notifications,
        title: 'CipherNest',
        body: 'Scanning for new photos...',
        ongoing: true,
      );

      final result = await AutoSyncService().runFullSync();

      // Show result notification
      if (result.synced > 0 || result.failed > 0) {
        final body = result.failed > 0
            ? '${result.synced} secured, ${result.failed} failed'
            : '${result.synced} photo${result.synced == 1 ? '' : 's'} secured';
        await _showNotification(
          notifications,
          title: 'CipherNest',
          body: body,
          ongoing: false,
        );
      } else {
        // Nothing to sync — dismiss notification
        await notifications.cancel(0);
      }

      return true;
    } catch (e) {
      debugPrint('Auto-sync worker error: $e');
      return false;
    }
  });
}

Future<void> _showNotification(
  FlutterLocalNotificationsPlugin notifications, {
  required String title,
  required String body,
  required bool ongoing,
}) async {
  await notifications.show(
    0,
    title,
    body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        'auto_sync_channel',
        'Auto-Sync',
        channelDescription: 'Background photo sync notifications',
        importance: ongoing ? Importance.low : Importance.defaultImportance,
        priority: ongoing ? Priority.low : Priority.defaultPriority,
        ongoing: ongoing,
        autoCancel: !ongoing,
      ),
    ),
  );
}
