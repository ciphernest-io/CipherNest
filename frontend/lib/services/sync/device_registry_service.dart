import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../database_service.dart';
import '../device_identity_service.dart';
import 'op_replay.dart';
import 'sync_coordinator.dart';
import 'sync_op.dart';

/// A device known to this vault, from `registerDevice` ops in the log.
class KnownDevice {
  final String id;
  final String name;
  final bool isThisDevice;
  const KnownDevice(
      {required this.id, required this.name, required this.isThisDevice});
}

/// Names this install in the shared op-log so conflict notices and the
/// Settings device list can say "your tablet" instead of a raw UUID.
///
/// The name is a plain `registerDevice` op — it converges like everything
/// else. Renaming records a new op (last-writer-wins on the name register).
class DeviceRegistryService {
  static final DeviceRegistryService _instance = DeviceRegistryService._();
  factory DeviceRegistryService() => _instance;
  DeviceRegistryService._();

  static const _kDeviceNamePref = 'device_name_v1';
  static const _kRegisteredNamePref = 'device_registered_name_v1';

  /// This device's display name (prefs; defaults to a platform label).
  Future<String> deviceName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kDeviceNamePref) ?? _defaultName();
  }

  String _defaultName() {
    if (Platform.isAndroid) return 'My Android phone';
    if (Platform.isIOS) return 'My iPhone';
    if (Platform.isMacOS) return 'My Mac';
    if (Platform.isWindows) return 'My PC';
    return 'My device';
  }

  Future<void> setDeviceName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDeviceNamePref, trimmed);
    await _register(trimmed);
  }

  /// Records a `registerDevice` op the first time, or whenever the name
  /// changed since we last registered. Cheap no-op otherwise. Call before a
  /// sync cycle so a fresh device announces itself.
  Future<void> ensureRegistered() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_kDeviceNamePref) ?? _defaultName();
    if (prefs.getString(_kRegisteredNamePref) == name) return;
    await _register(name);
  }

  Future<void> _register(String name) async {
    final id = await DeviceIdentityService().deviceId();
    await SyncCoordinator().record(SyncOpKind.registerDevice, id, name: name);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRegisteredNamePref, name);
  }

  /// All devices this vault has seen, this device first.
  Future<List<KnownDevice>> listDevices({required String accountId}) async {
    final thisId = await DeviceIdentityService().deviceId();
    final db = await DatabaseService().database;
    final opRows = await db.query('sync_ops',
        where: 'account_id = ?', whereArgs: [accountId]);
    final devices = replayOps(opRows.map(_rowToOp)).devices;
    final out = [
      for (final e in devices.entries)
        KnownDevice(id: e.key, name: e.value, isThisDevice: e.key == thisId),
    ];
    out.sort((a, b) {
      if (a.isThisDevice != b.isThisDevice) return a.isThisDevice ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return out;
  }

  /// Human-readable name for a device id, from the log; falls back to a
  /// short id fragment when the device never registered.
  Future<String> nameFor(String deviceId, {required String accountId}) async {
    final devices = await listDevices(accountId: accountId);
    for (final d in devices) {
      if (d.id == deviceId) return d.name;
    }
    return 'another device';
  }

  SyncOp _rowToOp(Map<String, Object?> row) => SyncOp.fromJson({
        'k': row['kind'],
        'd': row['device_id'],
        's': row['seq'],
        'h': {'w': row['hlc_wall'], 'c': row['hlc_counter']},
        't': row['target_id'],
        'n': row['name'],
        'f': row['folder_id'],
        'v': row['favorite'] == null ? null : (row['favorite'] as int) == 1,
      });
}
