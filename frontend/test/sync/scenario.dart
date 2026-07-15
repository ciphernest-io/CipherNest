/// Deterministic scenario generation. Same seed, same scenario, same
/// outcome — every failure message carries its seed for exact replay.
///
/// The canonical fleet is phone-and-tablet (two devices, both writing,
/// frequently offline, occasionally for weeks) — fleet sizes 3–5 exist to
/// shake out anything that only appears past pairwise.
library;

import 'dart:math';

import 'sim_model.dart';

sealed class SimEvent {
  const SimEvent();
}

class ActionEvent extends SimEvent {
  final LocalAction action;
  const ActionEvent(this.action);
}

class SyncEvent extends SimEvent {
  final int deviceIndex;

  /// Cloud calls allowed before a simulated crash; null = fault-free.
  final int? crashBudget;
  const SyncEvent(this.deviceIndex, {this.crashBudget});
}

class PartitionEvent extends SimEvent {
  final int deviceIndex;
  final bool offline;
  const PartitionEvent(this.deviceIndex, {required this.offline});
}

class TimeJumpEvent extends SimEvent {
  final int days;
  const TimeJumpEvent(this.days);
}

class ReinstallEvent extends SimEvent {
  final int deviceIndex;
  const ReinstallEvent(this.deviceIndex);
}

class CompactEvent extends SimEvent {
  final int deviceIndex;
  const CompactEvent(this.deviceIndex);
}

class LockEvent extends SimEvent {
  final int deviceIndex;
  final bool locked;
  const LockEvent(this.deviceIndex, {required this.locked});
}

class Scenario {
  final int seed;
  final int deviceCount;

  /// Per-device constant clock skew in ms (hours to days, both signs; at
  /// most one device gets a pathological offset).
  final List<int> clockSkewsMs;
  final List<SimEvent> events;

  const Scenario({
    required this.seed,
    required this.deviceCount,
    required this.clockSkewsMs,
    required this.events,
  });
}

Scenario generateScenario(
  int seed, {
  bool writerOnlyActions = false,
  // Terminal purge (permanent delete) is a product op validated by the
  // op-log engine test. The god / single-writer REFERENCE engines don't
  // model reinstall-vs-purge terminality, so their specificity gates omit
  // it (excluding it never weakens what those gates check: false positives
  // on a correct engine over the rest of the op set).
  bool includePurge = true,
}) {
  final rnd = Random(seed);

  // Phone-and-tablet is the canonical case: bias hard toward 2.
  final deviceCount = rnd.nextDouble() < 0.55 ? 2 : 2 + rnd.nextInt(4);

  final skews = List<int>.generate(deviceCount, (_) {
    final hours = rnd.nextInt(49) - 24; // ±24h
    return hours * 60 * 60 * 1000;
  });
  if (rnd.nextDouble() < 0.35) {
    // One persistently wrong clock: hours to ~400 days, either direction.
    final days = 1 + rnd.nextInt(400);
    skews[rnd.nextInt(deviceCount)] =
        (rnd.nextBool() ? 1 : -1) * days * msPerDay;
  }

  final events = <SimEvent>[];
  final fileIds = <String>[];
  final folderIds = <String>[];
  var nextFile = 0;
  var nextFolder = 0;
  var now = 0;

  int actionDevice() =>
      writerOnlyActions ? 0 : rnd.nextInt(deviceCount);

  final eventCount = 30 + rnd.nextInt(91); // 30..120
  for (var i = 0; i < eventCount; i++) {
    now += rnd.nextInt(60 * 60 * 1000); // up to an hour between events
    final roll = rnd.nextDouble();

    if (roll < 0.30) {
      final id = 'file${nextFile++}';
      fileIds.add(id);
      events.add(ActionEvent(LocalAction(
        kind: ActionKind.createFile,
        deviceIndex: actionDevice(),
        at: now,
        targetId: id,
        name: 'photo_$id.jpg',
        folderId: folderIds.isNotEmpty && rnd.nextBool()
            ? folderIds[rnd.nextInt(folderIds.length)]
            : null,
      )));
    } else if (roll < 0.40 && fileIds.isNotEmpty) {
      events.add(ActionEvent(LocalAction(
        kind: ActionKind.deleteFile,
        deviceIndex: actionDevice(),
        at: now,
        targetId: fileIds[rnd.nextInt(fileIds.length)],
      )));
    } else if (roll < 0.50 && fileIds.isNotEmpty) {
      events.add(ActionEvent(LocalAction(
        kind: ActionKind.renameFile,
        deviceIndex: actionDevice(),
        at: now,
        targetId: fileIds[rnd.nextInt(fileIds.length)],
        name: 'renamed_${rnd.nextInt(1000)}.jpg',
      )));
    } else if (roll < 0.60 && fileIds.isNotEmpty) {
      events.add(ActionEvent(LocalAction(
        kind: ActionKind.moveFile,
        deviceIndex: actionDevice(),
        at: now,
        targetId: fileIds[rnd.nextInt(fileIds.length)],
        folderId: folderIds.isNotEmpty && rnd.nextDouble() < 0.8
            ? folderIds[rnd.nextInt(folderIds.length)]
            : null,
      )));
    } else if (roll < 0.63 && fileIds.isNotEmpty) {
      events.add(ActionEvent(LocalAction(
        kind: ActionKind.setFavorite,
        deviceIndex: actionDevice(),
        at: now,
        targetId: fileIds[rnd.nextInt(fileIds.length)],
        favorite: rnd.nextBool(),
      )));
    } else if (roll < 0.645 && fileIds.isNotEmpty) {
      // Restore-from-bin: exercises delete/restore conflict resolution.
      events.add(ActionEvent(LocalAction(
        kind: ActionKind.restoreFile,
        deviceIndex: actionDevice(),
        at: now,
        targetId: fileIds[rnd.nextInt(fileIds.length)],
      )));
    } else if (roll < 0.66 && includePurge && fileIds.isNotEmpty) {
      // Permanent purge (30-day bin sweep) — terminal, must converge.
      events.add(ActionEvent(LocalAction(
        kind: ActionKind.purgeFile,
        deviceIndex: actionDevice(),
        at: now,
        targetId: fileIds[rnd.nextInt(fileIds.length)],
      )));
    } else if (roll < 0.72) {
      final id = 'folder${nextFolder++}';
      folderIds.add(id);
      events.add(ActionEvent(LocalAction(
        kind: ActionKind.createFolder,
        deviceIndex: actionDevice(),
        at: now,
        targetId: id,
        name: 'Folder $id',
        folderId: folderIds.length > 1 && rnd.nextDouble() < 0.3
            ? folderIds[rnd.nextInt(folderIds.length - 1)]
            : null,
      )));
    } else if (roll < 0.76 && folderIds.isNotEmpty) {
      events.add(ActionEvent(LocalAction(
        kind: ActionKind.deleteFolder,
        deviceIndex: actionDevice(),
        at: now,
        targetId: folderIds[rnd.nextInt(folderIds.length)],
      )));
    } else if (roll < 0.90) {
      events.add(SyncEvent(
        rnd.nextInt(deviceCount),
        crashBudget: rnd.nextDouble() < 0.20 ? rnd.nextInt(4) : null,
      ));
    } else if (roll < 0.94) {
      events.add(PartitionEvent(rnd.nextInt(deviceCount),
          offline: rnd.nextBool()));
    } else if (roll < 0.965) {
      // Weeks routinely; occasionally past the 180-day tombstone horizon.
      final days =
          rnd.nextDouble() < 0.15 ? 190 + rnd.nextInt(120) : 1 + rnd.nextInt(40);
      events.add(TimeJumpEvent(days));
      now += days * msPerDay;
    } else if (roll < 0.975) {
      events.add(ReinstallEvent(rnd.nextInt(deviceCount)));
    } else if (roll < 0.99) {
      events.add(CompactEvent(rnd.nextInt(deviceCount)));
    } else {
      events.add(
          LockEvent(rnd.nextInt(deviceCount), locked: rnd.nextBool()));
    }
  }

  return Scenario(
    seed: seed,
    deviceCount: deviceCount,
    clockSkewsMs: skews,
    events: events,
  );
}
