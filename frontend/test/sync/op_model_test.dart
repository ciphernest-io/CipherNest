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

  group('Model A folder lifecycle', () {
    test(
        'an individually-deleted file is never absorbed by a later folder '
        'delete, and stays deleted through the folder\'s restore', () {
      final state = replayOps([
        op(SyncOpKind.createFolder, 'A', name: 'A', wall: 1),
        op(SyncOpKind.createFile, 'f1', name: 'one.jpg', folder: 'A',
            wall: 2, seq: 1),
        op(SyncOpKind.createFile, 'f2', name: 'two.jpg', folder: 'A',
            wall: 3, seq: 2),
        op(SyncOpKind.deleteFile, 'f1', wall: 4, seq: 3),
        op(SyncOpKind.deleteFolder, 'A', wall: 5, seq: 4),
        op(SyncOpKind.restoreFolder, 'A', wall: 6, seq: 5),
      ]);
      final f1 = state.files['f1']!;
      expect(f1.deleted, isTrue,
          reason: 'individually-deleted file stays deleted');
      expect(f1.deletedByFolderId, isNull,
          reason: 'its bin entry is individual, never absorbed');
      final f2 = state.files['f2']!;
      expect(f2.deleted, isFalse, reason: 'cascade file restored');
      expect(f2.folderId, 'A');
      expect(state.folders['A']!.deleted, isFalse);
    });

    test('restoreFolder restores exactly the cascade set, nested and with '
        'metadata intact', () {
      final state = replayOps([
        op(SyncOpKind.createFolder, 'A', name: 'A', wall: 1),
        op(SyncOpKind.createFolder, 'B', name: 'B', folder: 'A', wall: 2,
            seq: 1),
        op(SyncOpKind.createFile, 'f1', name: 'deep.jpg', folder: 'B',
            wall: 3, seq: 2),
        op(SyncOpKind.setFavorite, 'f1', favorite: true, wall: 4, seq: 3),
        op(SyncOpKind.deleteFolder, 'A', wall: 5, seq: 4),
        op(SyncOpKind.restoreFolder, 'A', wall: 6, seq: 5),
      ]);
      expect(state.folders['A']!.deleted, isFalse);
      final b = state.folders['B']!;
      expect(b.deleted, isFalse, reason: 'cascade subfolder restored');
      expect(b.parentId, 'A');
      expect(b.deletedByFolderId, isNull, reason: 'cause cleared');
      final f1 = state.files['f1']!;
      expect(f1.deleted, isFalse);
      expect(f1.folderId, 'B');
      expect(f1.favorite, isTrue, reason: 'metadata survives the round trip');
    });

    test('concurrent restoreFolder vs foreign delete: later op wins, both '
        'directions', () {
      final base = [
        op(SyncOpKind.createFolder, 'A', name: 'A', wall: 1),
        op(SyncOpKind.createFile, 'f1', name: 'x.jpg', folder: 'A', wall: 2,
            seq: 1),
        op(SyncOpKind.deleteFolder, 'A', wall: 3, seq: 2),
      ];
      // Foreign re-delete orders AFTER my restore -> delete wins.
      final deleteWins = replayOps([
        ...base,
        op(SyncOpKind.restoreFolder, 'A', wall: 4, seq: 3),
        op(SyncOpKind.deleteFolder, 'A', device: 'devB', wall: 5),
      ]);
      expect(deleteWins.folders['A']!.deleted, isTrue);
      expect(deleteWins.files['f1']!.deleted, isTrue);
      expect(deleteWins.files['f1']!.deletedByFolderId, 'A',
          reason: 're-cascade re-stamps the cause');
      // My restore orders AFTER the foreign re-delete -> restore wins.
      final restoreWins = replayOps([
        ...base,
        op(SyncOpKind.deleteFolder, 'A', device: 'devB', wall: 4),
        op(SyncOpKind.restoreFolder, 'A', wall: 5, seq: 3),
      ]);
      expect(restoreWins.folders['A']!.deleted, isFalse);
      expect(restoreWins.files['f1']!.deleted, isFalse);
    });

    test('restore under a dead parent materializes at root, then rejoins '
        'the parent when IT is restored (structure remembered)', () {
      final ops = [
        op(SyncOpKind.createFolder, 'P', name: 'P', wall: 1),
        op(SyncOpKind.createFolder, 'C', name: 'C', folder: 'P', wall: 2,
            seq: 1),
        // C deleted directly (own bin entry), THEN P deleted.
        op(SyncOpKind.deleteFolder, 'C', wall: 3, seq: 2),
        op(SyncOpKind.deleteFolder, 'P', wall: 4, seq: 3),
        op(SyncOpKind.restoreFolder, 'C', wall: 5, seq: 4),
      ];
      final atRoot = materializeState(replayOps(ops));
      expect(atRoot.folders['C'], isNotNull, reason: 'C is live again');
      expect(atRoot.folders['C']!.parentId, isNull,
          reason: 'parent still deleted -> shows at root');
      final rejoined = materializeState(replayOps([
        ...ops,
        op(SyncOpKind.restoreFolder, 'P', wall: 6, seq: 5),
      ]));
      expect(rejoined.folders['C']!.parentId, 'P',
          reason: 'raw pointer preserved -> child rejoins restored parent');
    });

    test('moveFile into a folder restored before the move lands inside it',
        () {
      final state = replayOps([
        op(SyncOpKind.createFolder, 'A', name: 'A', wall: 1),
        op(SyncOpKind.createFile, 'f1', name: 'x.jpg', wall: 2, seq: 1),
        op(SyncOpKind.deleteFolder, 'A', wall: 3, seq: 2),
        op(SyncOpKind.restoreFolder, 'A', wall: 4, seq: 3),
        op(SyncOpKind.moveFile, 'f1', folder: 'A', wall: 5, seq: 4),
      ]);
      expect(state.files['f1']!.folderId, 'A');
      expect(state.files['f1']!.deleted, isFalse);
    });

    test('purgeFolder is terminal: no restore, no re-create; leftover '
        'cascade files stay individually recoverable', () {
      final state = replayOps([
        op(SyncOpKind.createFolder, 'A', name: 'A', wall: 1),
        op(SyncOpKind.createFile, 'f1', name: 'x.jpg', folder: 'A', wall: 2,
            seq: 1),
        op(SyncOpKind.deleteFolder, 'A', wall: 3, seq: 2),
        // Interrupted purge batch: the folder entity purged, the file's
        // purgeFile never recorded.
        op(SyncOpKind.purgeFolder, 'A', wall: 4, seq: 3),
        op(SyncOpKind.restoreFolder, 'A', wall: 5, seq: 4), // must no-op
        op(SyncOpKind.createFolder, 'A', name: 'imposter', wall: 6, seq: 5),
        op(SyncOpKind.restoreFile, 'f1', wall: 7, seq: 6),
      ]);
      expect(state.folders.containsKey('A'), isFalse,
          reason: 'purge is terminal — restore and re-create are dead');
      final f1 = state.files['f1']!;
      expect(f1.deleted, isFalse, reason: 'file individually restorable');
      expect(materializeState(state).live['f1']!.folderId, isNull,
          reason: 'its folder is gone -> root');
    });

    test('tombstone walls are explicit: individual wall vs cascade wall, '
        'cleared on restore', () {
      final state = replayOps([
        op(SyncOpKind.createFolder, 'A', name: 'A', wall: 1),
        op(SyncOpKind.createFile, 'f1', name: 'one.jpg', folder: 'A',
            wall: 2, seq: 1),
        op(SyncOpKind.createFile, 'f2', name: 'two.jpg', folder: 'A',
            wall: 3, seq: 2),
        op(SyncOpKind.deleteFile, 'f1', wall: 40, seq: 3),
        op(SyncOpKind.deleteFolder, 'A', wall: 50, seq: 4),
      ]);
      expect(state.files['f1']!.tombstoneWall, 40,
          reason: 'individual delete carries its own wall');
      expect(state.files['f2']!.tombstoneWall, 50,
          reason: 'cascade carries the deleteFolder\'s wall — the '
              'deleted_at=0 bug class, pinned at the replay layer');
      expect(state.folders['A']!.tombstoneWall, 50);
      final restored = replayOps([
        op(SyncOpKind.createFolder, 'A', name: 'A', wall: 1),
        op(SyncOpKind.createFile, 'f2', name: 'two.jpg', folder: 'A',
            wall: 3, seq: 2),
        op(SyncOpKind.deleteFolder, 'A', wall: 50, seq: 4),
        op(SyncOpKind.restoreFolder, 'A', wall: 60, seq: 5),
      ]);
      expect(restored.files['f2']!.tombstoneWall, isNull);
      expect(restored.files['f2']!.deletedByFolderId, isNull);
    });

    test(
        'SEED-178 REGRESSION: an explicit deleteFile issued while the file '
        'was cascade-binned survives the folder\'s restore (delete wins)',
        () {
      // The exact seed-178 interleaving: dev0 deletes the folder, dev1 —
      // concurrently, later in HLC order — individually deletes the file,
      // dev0 then restores the folder. Before the re-stamp rule the
      // restore resurrected the file over dev1's explicit delete.
      final state = replayOps([
        op(SyncOpKind.createFolder, 'F', name: 'F', device: 'devB', wall: 1),
        op(SyncOpKind.createFile, 'f4', name: 'photo.jpg', folder: 'F',
            device: 'devB', wall: 2, seq: 1),
        op(SyncOpKind.deleteFolder, 'F', wall: 3), // devA
        op(SyncOpKind.deleteFile, 'f4', device: 'devB', wall: 4, seq: 2),
        op(SyncOpKind.restoreFolder, 'F', wall: 5, seq: 1), // devA
      ]);
      final f4 = state.files['f4']!;
      expect(f4.deleted, isTrue,
          reason: 'the explicit individual delete must win');
      expect(f4.deletedByFolderId, isNull,
          reason: 're-stamped as an individual bin entry');
      expect(f4.tombstoneWall, 4,
          reason: 'wall follows the explicit deleteFile');
      expect(state.folders['F']!.deleted, isFalse,
          reason: 'the folder itself still restores');
    });

    test('deleteFile + deleteFolder commute: both orderings converge to '
        '(binned, cause null, deleteFile wall)', () {
      final shared = [
        op(SyncOpKind.createFolder, 'F', name: 'F', wall: 1),
        op(SyncOpKind.createFile, 'x', name: 'x.jpg', folder: 'F', wall: 2,
            seq: 1),
      ];
      final fileFirst = replayOps([
        ...shared,
        op(SyncOpKind.deleteFile, 'x', device: 'devB', wall: 3),
        op(SyncOpKind.deleteFolder, 'F', wall: 4, seq: 2),
      ]);
      final folderFirst = replayOps([
        ...shared,
        op(SyncOpKind.deleteFolder, 'F', wall: 3, seq: 2),
        op(SyncOpKind.deleteFile, 'x', device: 'devB', wall: 4),
      ]);
      for (final s in [fileFirst, folderFirst]) {
        final x = s.files['x']!;
        expect(x.deleted, isTrue);
        expect(x.deletedByFolderId, isNull);
      }
      expect(fileFirst.files['x']!.tombstoneWall, 3,
          reason: 'deleteFile wall (folder cascade skipped the binned file)');
      expect(folderFirst.files['x']!.tombstoneWall, 4,
          reason: 'deleteFile wall (re-stamp)');
    });

    test('folder twin: explicit deleteFolder on a cascade-binned folder '
        'survives the outer folder\'s restore', () {
      final state = replayOps([
        op(SyncOpKind.createFolder, 'P', name: 'P', wall: 1),
        op(SyncOpKind.createFolder, 'G', name: 'G', folder: 'P', wall: 2,
            seq: 1),
        op(SyncOpKind.deleteFolder, 'P', wall: 3, seq: 2), // G cause=P
        op(SyncOpKind.deleteFolder, 'G', device: 'devB', wall: 4),
        op(SyncOpKind.restoreFolder, 'P', wall: 5, seq: 3),
      ]);
      expect(state.folders['P']!.deleted, isFalse);
      final g = state.folders['G']!;
      expect(g.deleted, isTrue,
          reason: 'the explicit folder delete must win over P\'s restore');
      expect(g.deletedByFolderId, isNull,
          reason: 're-stamped as an independent bin entry');
    });

    test('renameFolder: LWW by order, dropped on a binned folder', () {
      final state = replayOps([
        op(SyncOpKind.createFolder, 'A', name: 'A', wall: 1),
        op(SyncOpKind.renameFolder, 'A', name: 'Mine', wall: 2, seq: 1),
        op(SyncOpKind.renameFolder, 'A', name: 'Theirs', device: 'devB',
            wall: 3),
        op(SyncOpKind.deleteFolder, 'A', wall: 4, seq: 2),
        op(SyncOpKind.renameFolder, 'A', name: 'Zombie', wall: 5, seq: 3),
      ]);
      expect(state.folders['A']!.name, 'Theirs',
          reason: 'later rename wins; rename after delete is dropped');
    });

    test('setFolderHidden: LWW, order- and duplicate-independent', () {
      final ops = [
        op(SyncOpKind.createFolder, 'A', name: 'A', wall: 1),
        op(SyncOpKind.setFolderHidden, 'A', favorite: true, wall: 2, seq: 1),
        op(SyncOpKind.setFolderHidden, 'A',
            favorite: false, device: 'devB', wall: 3),
        op(SyncOpKind.setFolderHidden, 'A', favorite: true, wall: 4, seq: 2),
      ];
      final baseline = replayOps(ops);
      expect(baseline.folders['A']!.hidden, isTrue,
          reason: 'the later-HLC hide wins');
      final rnd = Random(11);
      for (var i = 0; i < 25; i++) {
        final shuffled = List.of(ops)..shuffle(rnd);
        shuffled.add(shuffled[rnd.nextInt(shuffled.length)]);
        expect(replayOps(shuffled).folders['A']!.hidden, isTrue);
      }
    });

    test('setFolderHidden: survives deleteFolder cascade + restoreFolder',
        () {
      final state = replayOps([
        op(SyncOpKind.createFolder, 'A', name: 'A', wall: 1),
        op(SyncOpKind.setFolderHidden, 'A', favorite: true, wall: 2, seq: 1),
        op(SyncOpKind.deleteFolder, 'A', wall: 3, seq: 2),
        op(SyncOpKind.restoreFolder, 'A', wall: 4, seq: 3),
      ]);
      final a = state.folders['A']!;
      expect(a.deleted, isFalse);
      expect(a.hidden, isTrue,
          reason: 'the flag must ride through delete + restore untouched');
    });

    test('setFolderHidden: dropped on a binned folder (delete wins)', () {
      final state = replayOps([
        op(SyncOpKind.createFolder, 'A', name: 'A', wall: 1),
        op(SyncOpKind.deleteFolder, 'A', wall: 2, seq: 1),
        op(SyncOpKind.setFolderHidden, 'A', favorite: true, wall: 3, seq: 2),
      ]);
      expect(state.folders['A']!.hidden, isFalse,
          reason: 'a hide of a binned folder is dropped, mirroring rename');
    });

    test('setFolderHidden: purged or unknown id is a no-op', () {
      final state = replayOps([
        op(SyncOpKind.createFolder, 'A', name: 'A', wall: 1),
        op(SyncOpKind.purgeFolder, 'A', wall: 2, seq: 1),
        op(SyncOpKind.setFolderHidden, 'A', favorite: true, wall: 3, seq: 2),
        op(SyncOpKind.setFolderHidden, 'ghost',
            favorite: true, wall: 4, seq: 3),
      ]);
      expect(state.folders.containsKey('A'), isFalse,
          reason: 'purge is terminal; the hide must not resurrect the row');
      expect(state.folders.containsKey('ghost'), isFalse);
    });

    test('setFileHidden: LWW, order-independent, and NEVER clobbers '
        'setFavorite (shared payload field, distinct kinds)', () {
      final ops = [
        op(SyncOpKind.createFile, 'x', name: 'x.jpg', wall: 1),
        op(SyncOpKind.setFileHidden, 'x', favorite: true, wall: 2, seq: 1),
        op(SyncOpKind.setFavorite, 'x', favorite: true, wall: 3, seq: 2),
        op(SyncOpKind.setFileHidden, 'x',
            favorite: false, device: 'devB', wall: 4),
        op(SyncOpKind.setFileHidden, 'x', favorite: true, wall: 5, seq: 3),
      ];
      final baseline = replayOps(ops);
      expect(baseline.files['x']!.hidden, isTrue);
      expect(baseline.files['x']!.favorite, isTrue,
          reason: 'the hide ops must not touch the favorite flag');
      final rnd = Random(13);
      for (var i = 0; i < 25; i++) {
        final shuffled = List.of(ops)..shuffle(rnd);
        final s = replayOps(shuffled);
        expect(s.files['x']!.hidden, isTrue);
        expect(s.files['x']!.favorite, isTrue);
      }
    });

    test('setFileHidden: survives deleteFile + restoreFile untouched', () {
      final state = replayOps([
        op(SyncOpKind.createFile, 'x', name: 'x.jpg', wall: 1),
        op(SyncOpKind.setFileHidden, 'x', favorite: true, wall: 2, seq: 1),
        op(SyncOpKind.deleteFile, 'x', wall: 3, seq: 2),
        op(SyncOpKind.restoreFile, 'x', wall: 4, seq: 3),
      ]);
      final x = state.files['x']!;
      expect(x.deleted, isFalse);
      expect(x.hidden, isTrue);
    });

    test('setFileHidden: dropped on a binned file (delete wins)', () {
      final state = replayOps([
        op(SyncOpKind.createFile, 'x', name: 'x.jpg', wall: 1),
        op(SyncOpKind.deleteFile, 'x', wall: 2, seq: 1),
        op(SyncOpKind.setFileHidden, 'x', favorite: true, wall: 3, seq: 2),
      ]);
      expect(state.files['x']!.hidden, isFalse);
    });

    test('setFileHidden: purged or unknown id is a no-op', () {
      final state = replayOps([
        op(SyncOpKind.createFile, 'x', name: 'x.jpg', wall: 1),
        op(SyncOpKind.deleteFile, 'x', wall: 2, seq: 1),
        op(SyncOpKind.purgeFile, 'x', wall: 3, seq: 2),
        op(SyncOpKind.setFileHidden, 'x', favorite: true, wall: 4, seq: 3),
        op(SyncOpKind.setFileHidden, 'ghost',
            favorite: true, wall: 5, seq: 4),
      ]);
      expect(state.files.containsKey('x'), isFalse,
          reason: 'purge is terminal; the hide must not resurrect the row');
      expect(state.files.containsKey('ghost'), isFalse);
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
          } else if (roll < 0.78) {
            action = LocalAction(
                kind: ActionKind.setFavorite,
                deviceIndex: 0,
                at: i,
                targetId: fileIds[rnd.nextInt(fileIds.length)],
                favorite: rnd.nextBool());
          } else if (roll < 0.8) {
            action = LocalAction(
                kind: ActionKind.purgeFile,
                deviceIndex: 0,
                at: i,
                targetId: fileIds[rnd.nextInt(fileIds.length)]);
          } else if (roll < 0.86) {
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
          } else if (roll < 0.89 && folderIds.isNotEmpty) {
            action = LocalAction(
                kind: ActionKind.moveFolder,
                deviceIndex: 0,
                at: i,
                targetId: folderIds[rnd.nextInt(folderIds.length)],
                folderId: rnd.nextDouble() < 0.8
                    ? folderIds[rnd.nextInt(folderIds.length)]
                    : null);
          } else if (roll < 0.91 && folderIds.isNotEmpty) {
            action = LocalAction(
                kind: ActionKind.renameFolder,
                deviceIndex: 0,
                at: i,
                targetId: folderIds[rnd.nextInt(folderIds.length)],
                name: 'Renamed $i');
          } else if (roll < 0.95 && folderIds.isNotEmpty) {
            action = LocalAction(
                kind: ActionKind.deleteFolder,
                deviceIndex: 0,
                at: i,
                targetId: folderIds[rnd.nextInt(folderIds.length)]);
          } else if (roll < 0.98 && folderIds.isNotEmpty) {
            action = LocalAction(
                kind: ActionKind.restoreFolder,
                deviceIndex: 0,
                at: i,
                targetId: folderIds[rnd.nextInt(folderIds.length)]);
          } else if (folderIds.isNotEmpty) {
            action = LocalAction(
                kind: ActionKind.purgeFolder,
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

        // Full-state equality through the ONE shared materialization
        // mapping — live sets, bin sets, cascade causes, both folder maps,
        // and the normalization rule all pinned at once.
        final replayed = materializeState(replayOps(ops));
        final refState = reference.snapshot();
        expect(replayed == refState, isTrue,
            reason: 'seed $seed diverged:\n${replayed.diff(refState)}');
      }
    });
  });
}
