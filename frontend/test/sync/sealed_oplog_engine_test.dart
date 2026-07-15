/// Stage 2c under the harness: the op-log engine with REAL sealed segments.
/// Every segment in the simulated cloud is an actual format-v1 .cnest blob,
/// HPKE-sealed to a real vault public key and opened with the real private
/// key — the crypto path production will use, not a stand-in.
library;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/key_manager_service.dart';
import 'package:ciphernest/services/sync/segment_codec.dart';
import 'package:ciphernest/services/sync/sync_op.dart';

import 'harness.dart';
import 'oplog_adapter.dart';
import 'scenario.dart';
import 'sim_model.dart';

/// The plain adapter with the payload codec swapped for the real thing.
/// All sim devices share one vault (one user, one seed phrase), so the
/// singleton KeyManagerService legitimately serves them all.
class SealedOpLogSimEngine extends OpLogSimEngine {
  SealedOpLogSimEngine(super.deviceId, super.clock);

  @override
  Future<Object> encodeSegment(List<SyncOp> ops) async {
    final sealed = await SegmentCodec.seal(ops);
    if (sealed == null) {
      throw StateError('seal failed — no vault public key in test setup');
    }
    return sealed;
  }

  @override
  Future<List<SyncOp>?> decodeSegment(Object payload) async {
    if (payload is! Uint8List) return null;
    // A payload is either a segment or a snapshot; try both (real codecs).
    final seg = await SegmentCodec.tryOpen(payload);
    if (seg != null) return seg;
    final snap = await SegmentCodec.tryOpenSnapshot(payload);
    return snap?.ops;
  }

  @override
  Future<Object> encodeSnapshot(List<SyncOp> ops) async {
    final sealed =
        await SegmentCodec.sealSnapshot(foldedNames: const [], ops: ops);
    if (sealed == null) throw StateError('snapshot seal failed');
    return sealed;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // DETERMINISTIC key: the KeyManagerService singleton is process-wide and
  // shared across concurrently-running sync test files. Installing the SAME
  // keypair everywhere makes that sharing harmless — a segment sealed in one
  // test opens in another. (Random per-test keys corrupt each other's
  // in-flight seal/open under the runner's async interleaving.)
  setUp(() async {
    final keyPair = await X25519().newKeyPairFromSeed(
        Uint8List.fromList(List<int>.generate(32, (i) => i + 1)));
    KeyManagerService().installKeysForTest(
      keyPair: keyPair,
      publicKey: await keyPair.extractPublicKey(),
    );
  });

  test(
      'sealed op-log engine: 40 seeds, real HPKE segments, all invariants',
      () async {
    for (var seed = 0; seed < 40; seed++) {
      final result = await runScenario(
        generateScenario(seed),
        (deviceId, clock) => SealedOpLogSimEngine(deviceId, clock),
      );
      if (!result.passed) {
        failWithSeed(seed, result.violations);
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
