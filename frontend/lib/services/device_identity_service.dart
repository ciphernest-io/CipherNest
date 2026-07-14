import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Stable per-install device identity for multi-device coordination.
///
/// Minted on first access, kept in Keystore-wrapped secure storage, and
/// DELIBERATELY absent from the DB backup: a restored snapshot must never
/// carry another device's identity, or two devices would start writing under
/// one id. A reinstall mints a fresh id by design — that is a feature, not a
/// loss: it is what makes per-device names (Stage 1 snapshots, Stage 2
/// op-log sequence numbers) structurally collision-proof.
class DeviceIdentityService {
  static final DeviceIdentityService _instance = DeviceIdentityService._();
  factory DeviceIdentityService() => _instance;
  DeviceIdentityService._();

  static const String _kDeviceId = 'device_id_v1';

  final _storage = const FlutterSecureStorage();
  String? _cached;

  /// This install's identity. Mints and persists a UUID on first call.
  Future<String> deviceId() async {
    final cached = _cached;
    if (cached != null) return cached;
    var id = await _storage.read(key: _kDeviceId);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await _storage.write(key: _kDeviceId, value: id);
    }
    _cached = id;
    return id;
  }

  @visibleForTesting
  void setForTest(String? id) => _cached = id;
}
