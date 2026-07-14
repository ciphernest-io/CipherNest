/// Hybrid Logical Clock — the ordering backbone of the multi-device op-log.
///
/// Why HLC (locked in the approved Plan 2 design):
///  * Wall clocks are untrusted; Lamport clocks lose wall-time affinity;
///    vector clocks cost O(devices) and still need a tiebreak.
///  * HLC gives a TOTAL order via `(wallMs, counter)` + deviceId tiebreak,
///    guarantees causal monotonicity (an op created after seeing another
///    always orders after it), and stays close to real time when clocks
///    are sane.
///
/// Design decision — NO receive-side clamping of wrong clocks: any
/// adjustment based on the *receiver's* clock would make an op's effective
/// position differ between devices and destroy convergence (invariant 1).
/// An op's HLC is fixed at creation, forever, on every device. A
/// persistently-future clock can therefore win LWW ties on concurrent
/// cosmetic edits (rename/move) until other clocks catch up — bounded,
/// converged, and never destructive, because creates are unique and deletes
/// are not LWW. Surfacing "this device's clock looks wrong" is a UI concern
/// (device registry, Stage 2g), not a core one.
library;

class Hlc implements Comparable<Hlc> {
  /// Physical component, ms since epoch (as claimed by the creating device).
  final int wallMs;

  /// Logical component: breaks ties within one millisecond and carries
  /// causality when the physical clock stalls or runs behind.
  final int counter;

  const Hlc(this.wallMs, this.counter)
      : assert(wallMs >= 0),
        assert(counter >= 0);

  static const Hlc zero = Hlc(0, 0);

  /// Clock advance for a LOCAL event (an op this device is creating).
  static Hlc send(Hlc last, int physicalMs) {
    if (physicalMs > last.wallMs) return Hlc(physicalMs, 0);
    return Hlc(last.wallMs, last.counter + 1);
  }

  /// Clock advance on RECEIVING a remote op. Guarantees every later local
  /// op orders after everything this device has seen.
  static Hlc receive(Hlc local, Hlc remote, int physicalMs) {
    if (physicalMs > local.wallMs && physicalMs > remote.wallMs) {
      return Hlc(physicalMs, 0);
    }
    if (local.wallMs == remote.wallMs) {
      return Hlc(local.wallMs,
          (local.counter > remote.counter ? local.counter : remote.counter) +
              1);
    }
    if (local.wallMs > remote.wallMs) {
      return Hlc(local.wallMs, local.counter + 1);
    }
    return Hlc(remote.wallMs, remote.counter + 1);
  }

  @override
  int compareTo(Hlc other) {
    final w = wallMs.compareTo(other.wallMs);
    if (w != 0) return w;
    return counter.compareTo(other.counter);
  }

  bool operator <(Hlc other) => compareTo(other) < 0;
  bool operator >(Hlc other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc && other.wallMs == wallMs && other.counter == counter;

  @override
  int get hashCode => Object.hash(wallMs, counter);

  Map<String, dynamic> toJson() => {'w': wallMs, 'c': counter};

  factory Hlc.fromJson(Map<String, dynamic> json) =>
      Hlc(json['w'] as int, json['c'] as int);

  @override
  String toString() => 'Hlc($wallMs.$counter)';
}
