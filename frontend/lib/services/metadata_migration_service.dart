import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../src/models/file_model.dart';
import 'cloud/cloud_service.dart';
import 'cloud/sealed_metadata.dart';

/// One-time migration: rewrites legacy plaintext cloud metadata
/// (Drive `appProperties.original_name`/`type`, OneDrive name-encoded
/// filenames) to the HPKE-sealed format.
///
/// Metadata-only — Drive gets a `files.update`, OneDrive a rename; blob
/// content is never re-uploaded. Idempotent and resumable: already-sealed
/// entries are skipped, so re-running after an interruption just picks up
/// where it left off. Per-file failures are counted and skipped, never
/// fatal.
///
/// Sealing needs only the vault public key, but this runs from Settings on
/// an unlocked foreground session anyway.
class MetadataMigrationService {
  static final MetadataMigrationService _instance =
      MetadataMigrationService._();
  factory MetadataMigrationService() => _instance;
  MetadataMigrationService._();

  /// Prefs: legacy entries remaining after the last scan/run (per active
  /// account is overkill pre-launch — one vault exists).
  static const String kLegacyRemainingPref = 'meta_migration_remaining_v1';

  final ValueNotifier<MetadataMigrationState> state =
      ValueNotifier(const MetadataMigrationState.idle());

  bool get isRunning => state.value.phase == MetadataMigrationPhase.running;

  /// Counts vault entries still carrying legacy plaintext metadata.
  Future<int> scanLegacyCount() async {
    final files = await CloudService().listCloudFiles();
    final n = files.where(_isLegacy).length;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kLegacyRemainingPref, n);
    return n;
  }

  bool _isLegacy(Map<String, dynamic> f) {
    if (f['sealed_meta'] != null) return false;
    final legacyName = f['original_name'] as String?;
    final legacyType = f['type'] as String?;
    return (legacyName != null && legacyName.isNotEmpty) ||
        (legacyType != null && legacyType.isNotEmpty);
  }

  /// Runs the migration over every legacy entry. Safe to call repeatedly.
  Future<MetadataMigrationState> run() async {
    if (isRunning) return state.value;
    state.value = const MetadataMigrationState.idle();

    try {
      final files = await CloudService().listCloudFiles();
      final legacy = files.where(_isLegacy).toList();
      var done = 0, failed = 0;
      state.value = MetadataMigrationState(
        phase: MetadataMigrationPhase.running,
        total: legacy.length,
        done: 0,
        failed: 0,
      );

      for (final f in legacy) {
        try {
          final stem =
              (f['name'] as String? ?? '').replaceAll('.cnest', '');
          final name = (f['original_name'] as String?)?.isNotEmpty == true
              ? f['original_name'] as String
              : stem;
          final type = CnestFileTypeWire.fromWire(f['type'] as String?) ??
              CnestFileTypeWire.fromFilename(name);

          final sealed = await SealedMetadata.seal(name: name, type: type);
          if (sealed == null) {
            throw StateError('No vault public key — cannot seal');
          }
          await CloudService().sealLegacyMetadata(
            cloudId: f['id'] as String,
            cloudName: (f['cloud_name'] ?? f['name']) as String,
            sealedMeta: sealed,
          );
          done++;
        } catch (e) {
          failed++;
          debugPrint('Metadata migration: ${f['id']} failed: $e');
        }
        state.value = state.value.copyWith(done: done, failed: failed);
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(kLegacyRemainingPref, failed);
      state.value = state.value.copyWith(
        phase: MetadataMigrationPhase.done,
      );
    } catch (e) {
      debugPrint('Metadata migration aborted: $e');
      state.value = state.value.copyWith(
        phase: MetadataMigrationPhase.error,
        message: e.toString(),
      );
    }
    return state.value;
  }
}

enum MetadataMigrationPhase { idle, running, done, error }

class MetadataMigrationState {
  final MetadataMigrationPhase phase;
  final int total;
  final int done;
  final int failed;
  final String? message;

  const MetadataMigrationState({
    required this.phase,
    this.total = 0,
    this.done = 0,
    this.failed = 0,
    this.message,
  });

  const MetadataMigrationState.idle()
      : phase = MetadataMigrationPhase.idle,
        total = 0,
        done = 0,
        failed = 0,
        message = null;

  MetadataMigrationState copyWith({
    MetadataMigrationPhase? phase,
    int? done,
    int? failed,
    String? message,
  }) {
    return MetadataMigrationState(
      phase: phase ?? this.phase,
      total: total,
      done: done ?? this.done,
      failed: failed ?? this.failed,
      message: message ?? this.message,
    );
  }
}
