/// Simulated cloud storage + fault injection for the sync harness.
library;

import 'sim_model.dart';

/// Thrown by [SimCloud] when a device's crash budget is exhausted —
/// simulates the process dying mid-sync between two cloud operations.
/// Engines must be crash-safe at EVERY prefix of every cloud interaction.
class SimCrash implements Exception {
  final String device;
  const SimCrash(this.device);
  @override
  String toString() => 'SimCrash($device)';
}

/// Thrown when a partitioned (offline) device touches the cloud.
class SimOffline implements Exception {
  final String device;
  const SimOffline(this.device);
  @override
  String toString() => 'SimOffline($device)';
}

class CloudObject {
  final String name;
  final Object payload; // structured, inspectable by the oracle
  final SimTime uploadedAt; // provider timestamp (compaction safety floor)

  const CloudObject({
    required this.name,
    required this.payload,
    required this.uploadedAt,
  });
}

/// Append-only-friendly object store with per-device partitions and crash
/// budgets. Payloads are structured objects, not bytes: real segments are
/// HPKE-sealed at the IO boundary in production, which is orthogonal to the
/// ordering/convergence properties this harness exists to test (the crypto
/// has its own vectors and tests).
class SimCloud {
  final Map<String, CloudObject> _objects = {};
  final Set<String> _offline = {};
  final Map<String, int> _crashBudget = {};

  /// The harness's global clock, used to stamp provider upload times.
  SimTime now = 0;

  int _opCount = 0;
  int get operationCount => _opCount;

  // ---- fault injection -----------------------------------------------------

  void setOffline(String device, bool offline) {
    offline ? _offline.add(device) : _offline.remove(device);
  }

  bool isOffline(String device) => _offline.contains(device);

  /// The device's next [budget] cloud calls succeed; the one after crashes.
  /// Null budget = unlimited.
  void setCrashBudget(String device, int? budget) {
    if (budget == null) {
      _crashBudget.remove(device);
    } else {
      _crashBudget[device] = budget;
    }
  }

  void _gate(String device) {
    _opCount++;
    if (_offline.contains(device)) throw SimOffline(device);
    final budget = _crashBudget[device];
    if (budget != null) {
      if (budget <= 0) {
        _crashBudget.remove(device);
        throw SimCrash(device);
      }
      _crashBudget[device] = budget - 1;
    }
  }

  // ---- storage API (what providers give the real engine) --------------------

  /// Objects are immutable once written; writing an existing name is a
  /// harness-detectable design smell, so it throws unless [replace].
  void put(String device, String name, Object payload,
      {bool replace = false}) {
    _gate(device);
    if (!replace && _objects.containsKey(name)) {
      throw StateError(
          'SimCloud: "$name" already exists and replace=false — append-only '
          'discipline violated by $device');
    }
    _objects[name] = CloudObject(name: name, payload: payload, uploadedAt: now);
  }

  Object? get(String device, String name) {
    _gate(device);
    return _objects[name]?.payload;
  }

  List<CloudObject> list(String device, {String? prefix}) {
    _gate(device);
    final out = _objects.values
        .where((o) => prefix == null || o.name.startsWith(prefix))
        .toList();
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  void delete(String device, String name) {
    _gate(device);
    _objects.remove(name);
  }

  // ---- oracle access (no gating: the oracle is omniscient) ------------------

  List<CloudObject> inspectAll({String? prefix}) => _objects.values
      .where((o) => prefix == null || o.name.startsWith(prefix))
      .toList();

  bool exists(String name) => _objects.containsKey(name);
}
