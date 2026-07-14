/// Unit tests for the op-log core: HLC laws, replay determinism, CRDT
/// semantics, and sequential equivalence with the reference state machine.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/sync/hlc.dart';
import 'package:ciphernest/services/sync/op_replay.dart';
import 'package:ciphernest/services/sync/sync_op.dart';

import 'oplog_adapter.dart';
import 'sim_model.dart';
import 'state_machine.dart';

SyncOp op(
  SyncOpKind kind,
  String target, {
  String device = 'devA',
  int seq = 0,
  int wall = 0,
  int counter = 0,
  String? name,
  String? folder,
  bool? favorite,
}) =>
    SyncOp(
      kind: kind,
      deviceId: device,
      seq: seq,
      hlc: Hlc(wall, counter),
      targetId: target,
      name: name,
      folderId: folder,
      favorite: favorite,
    );

void main() {
  group('HLC laws', () {
    test('send is strictly monotonic even with a frozen or reversed clock',
        () {
      var hlc = Hlc.zero;
      for (final physical in [100, 100, 100, 50, 20, 100, 101]) {
        final next = Hlc.send(hlc, physical);
        expect(next > hlc, isTrue,
            reason: 'send must always advance ($hlc -> $next @ $physical)');
        hlc = next;
      }
    });

    test('receive orders after both local and remote', () {
      const local = Hlc(1000, 3);
      const remote = Hlc(5000, 7); // remote clock far ahead
      final merged = Hlc.receive(local, remote, 1001);
      expect(merged > local, isTrue);
      expect(merged > remote, isTrue);
    });

    test('an op created after seeing a remote op orders after it', () {
      // Device B has a clock 2 days BEHIND device A.
      const remoteFromA = Hlc(2 * msPerDay, 0);
      var b = Hlc.zero;
      b = Hlc.receive(b, remoteFromA, 100); // B's wall clock says 100ms
      final bNext = Hlc.send(b, 101);
      expect(bNext > remoteFromA, isTrue,
          reason: 'causality must survive clock skew');
    });

    test('json round trip', () {
      const h = Hlc(123456789, 42);
      expect(Hlc.fromJson(h.toJson()), h);
    });
  });

  group('replay determinism', () {
    test('replay is a pure function of the op SET (order + dups ignored)',
        () {
      final ops = <SyncOp>[
        op(SyncOpKind.createFolder, 'd1', name: 'Docs', wall: 1),
        op(SyncOpKind.createFile, 'f1',
            name: 'a.jpg', folder: 'd1', wall: 2, seq: 1),
        op(SyncOpKind.createFile, 'f2', name: 'b.jpg', wall: 3, seq: 2),
        op(SyncOpKind.renameFile, 'f1',
            name: 'renamed.jpg', device: 'devB', wall: 4),
        op(SyncOpKind.deleteFile, 'f2', device: 'devB', wall: 5, seq: 1),
        op(SyncOpKind.moveFile, 'f1', folder: null, wall: 6, seq: 3),
        op(SyncOpKind.deleteFolder, 'd1', device: 'devC', wall: 7),
      ];

      final baseline = replayOps(ops);
      final rnd = Random(7);
      for (var i = 0; i < 50; i++) {
        final shuffled = List.of(ops)..shuffle(rnd);
        // Inject duplicates too.
        shuffled.addAll(
            List.generate(3, (_) => shuffled[rnd.nextInt(shuffled.length)]));
        final replayed = replayOps(shuffled);
        expect(replayed.files.length, baseline.files.length);
        for (final e in baseline.files.entries) {
          final other = replayed.files[e.key]!;
          expect(other.name, e.value.name, reason: 'shuffle $i, ${e.key}');
          expect(other.folderId, e.value.folderId);
          expect(other.deleted, e.value.deleted);
          expect(other.favorite, e.value.favorite);
        }
      }
    });
  });

  group('CRDT semantics', () {
    test('delete wins over later-ordering edits, softly (stays binned)', () {
      final state = replayOps([
        op(SyncOpKind.createFile, 'f1', name: 'x.jpg', wall: 1),
        op(SyncOpKind.deleteFile, 'f1', wall: 2, seq: 1),
        op(SyncOpKind.renameFile, 'f1',
            name: 'sneaky.jpg', device: 'devB', wall: 3),
        op(SyncOpKind.setFavorite, 'f1', favorite: true, device: 'devB',
            wall: 4, seq: 1),
      ]);
      final f = state.files['f1']!;
      expect(f.deleted, isTrue, reason: 'no resurrection');
      expect(f.name, 'x.jpg', reason: 'edits after delete are ignored');
      expect(f.favorite, isFalse);
    });

    test('duplicate create (same uuid) is dead on arrival', () {
      final state = replayOps([
        op(SyncOpKind.createFile, 'f1', name: 'first.jpg', wall: 1),
        op(SyncOpKind.createFile, 'f1',
            name: 'imposter.jpg', device: 'devB', wall: 2),
      ]);
      expect(state.files['f1']!.name, 'first.jpg');
    });

    test('defensive pre-tombstone: delete-before-create stays dead', () {
      final state = replayOps([
        op(SyncOpKind.deleteFile, 'f1', wall: 1),
        op(SyncOpKind.createFile, 'f1', name: 'zombie.jpg', wall: 2, seq: 1),
      ]);
      expect(state.files['f1']!.deleted, isTrue);
    });

    test('concurrent folder moves that would form a cycle: one is skipped, '
        'deterministically', () {
      final state = replayOps([
        op(SyncOpKind.createFolder, 'A', name: 'A', wall: 1),
        op(SyncOpKind.createFolder, 'B', name: 'B', wall: 2, seq: 1),
        // Concurrent: A -> under B (devA), B -> under A (devB).
        op(SyncOpKind.moveFolder, 'A', folder: 'B', wall: 10, seq: 2),
        op(SyncOpKind.moveFolder, 'B',
            folder: 'A', device: 'devB', wall: 10),
      ]);
      // Total order: devA's op sorts first (same HLC, 'devA' < 'devB').
      expect(state.folders['A']!.parentId, 'B');
      expect(state.folders['B']!.parentId, isNull,
          reason: 'the cycle-forming move must be skipped');
    });

    test('folder delete bins its subtree; late move-in lands at root', () {
      final state = replayOps([
        op(SyncOpKind.createFolder, 'A', name: 'A', wall: 1),
        op(SyncOpKind.createFolder, 'B', name: 'B', folder: 'A', wall: 2,
            seq: 1),
        op(SyncOpKind.createFile, 'f1', name: 'in-b.jpg', folder: 'B',
            wall: 3, seq: 2),
        op(SyncOpKind.createFile, 'f2', name: 'late.jpg', wall: 4, seq: 3),
        op(SyncOpKind.deleteFolder, 'A', wall: 5, seq: 4),
        // Concurrent move of f2 into B orders after the folder delete.
        op(SyncOpKind.moveFile, 'f2', folder: 'B', device: 'devB', wall: 6),
      ]);
      expect(state.files['f1']!.deleted, isTrue,
          reason: 'subtree file binned with the folder');
      expect(state.files['f2']!.deleted, isFalse,
          reason: 'late move-in survives');
      expect(state.files['f2']!.folderId, isNull,
          reason: 'destination folder is gone -> root');
      expect(state.folders['A']!.deleted, isTrue);
      expect(state.folders['B']!.deleted, isTrue);
    });
  });

  group('sequential equivalence with the reference state machine', () {
    test('random single-device histories: replay == StateMachine', () {
      for (var seed = 0; seed < 40; seed++) {
        final rnd = Random(seed);
        final reference = StateMachine();
        final ops = <SyncOp>[];
        var hlc = Hlc.zero;
        var seq = 0;
        final fileIds = <String>[];
        final folderIds = <String>[];

        for (var i = 0; i < 80; i++) {
          final roll = rnd.nextDouble();
          LocalAction? action;
          if (roll < 0.35 || fileIds.isEmpty) {
            final id = 'f${fileIds.length}';
            fileIds.add(id);
            action = LocalAction(
                kind: ActionKind.createFile,
                deviceIndex: 0,
                at: i,
                targetId: id,
                name: 'n$i.jpg',
                folderId: folderIds.isNotEmpty && rnd.nextBool()
                    ? folderIds[rnd.nextInt(folderIds.length)]
                    : null);
          } else if (roll < 0.5) {
            action = LocalAction(
                kind: ActionKind.deleteFile,
                deviceIndex: 0,
                at: i,
                targetId: fileIds[rnd.nextInt(fileIds.length)]);
          } else if (roll < 0.56) {
            action = LocalAction(
                kind: ActionKind.restoreFile,
                deviceIndex: 0,
                at: i,
                targetId: fileIds[rnd.nextInt(fileIds.length)]);
          } else if (roll < 0.62) {
            action = LocalAction(
                kind: ActionKind.renameFile,
                deviceIndex: 0,
                at: i,
                targetId: fileIds[rnd.nextInt(fileIds.length)],
                name: 'r$i.jpg');
          } else if (roll < 0.74) {
            action = LocalAction(
                kind: ActionKind.moveFile,
                deviceIndex: 0,
                at: i,
                targetId: fileIds[rnd.nextInt(fileIds.length)],
                folderId: folderIds.isNotEmpty && rnd.nextBool()
                    ? folderIds[rnd.nextInt(folderIds.length)]
                    : null);
          } else if (roll < 0.84) {
            action = LocalAction(
                kind: ActionKind.setFavorite,
                deviceIndex: 0,
                at: i,
                targetId: fileIds[rnd.nextInt(fileIds.length)],
                favorite: rnd.nextBool());
          } else if (roll < 0.93) {
            final id = 'd${folderIds.length}';
            folderIds.add(id);
            action = LocalAction(
                kind: ActionKind.createFolder,
                deviceIndex: 0,
                at: i,
                targetId: id,
                name: 'Folder $id',
                folderId: folderIds.length > 1 && rnd.nextBool()
                    ? folderIds[rnd.nextInt(folderIds.length - 1)]
                    : null);
          } else if (folderIds.isNotEmpty) {
            action = LocalAction(
                kind: ActionKind.deleteFolder,
                deviceIndex: 0,
                at: i,
                targetId: folderIds[rnd.nextInt(folderIds.length)]);
          }
          if (action == null) continue;

          reference.apply(action);
          hlc = Hlc.send(hlc, i);
          ops.add(opFromAction(action,
              deviceId: 'dev0', seq: seq++, hlc: hlc));
        }

        final replayed = replayOps(ops);
        final refState = reference.snapshot();

        final live = {
          for (final e in replayed.files.entries)
            if (!e.value.deleted)
              e.key: FileMeta(
                  name: e.value.name,
                  folderId: e.value.folderId,
                  favorite: e.value.favorite)
        };
        final binned = {
          for (final e in replayed.files.entries)
            if (e.value.deleted)
              e.key: FileMeta(
                  name: e.value.name,
                  folderId: e.value.folderId,
                  favorite: e.value.favorite)
        };
        expect(live, refState.live, reason: 'seed $seed live set diverged');
        expect(binned.keys.toSet(), refState.binned.keys.toSet(),
            reason: 'seed $seed binned set diverged');
      }
    });
  });
}
