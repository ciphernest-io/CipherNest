/// Derived device albums: one virtual album per distinct album-folder name
/// across all device subtrees under the account's Phone Backup root, with
/// contents = the union of those folders. View-layer only — these tests
/// seed the folder tree directly (as auto-sync's deterministic creates
/// would) and check the grouping, union, exclusion, and count rules.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/database_service.dart';
import 'package:ciphernest/services/system_folders.dart';
import 'package:ciphernest/src/models/file_model.dart';

const _acct = 'google_test@example.com';
const _other = 'second@example.com';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  final keyA = SystemFolders.deviceKey('samsung', 'SM-A556E');
  final keyB = SystemFolders.deviceKey('vivo', 'V2158');
  final rootId = SystemFolders.rootId(_acct);
  final devA = SystemFolders.deviceId(_acct, keyA);
  final devB = SystemFolders.deviceId(_acct, keyB);
  final camA = SystemFolders.albumId(_acct, keyA, 'Camera');
  final camB = SystemFolders.albumId(_acct, keyB, 'Camera');
  final shotsA = SystemFolders.albumId(_acct, keyA, 'Screenshots');

  Future<void> folder(String id, String name,
      {String? parent,
      String account = _acct,
      bool deleted = false,
      bool hiddenEffective = false}) async {
    await db.insert('folders', {
      'id': id,
      'account_id': account,
      'name': name,
      'parent_id': parent,
      'is_system': 1,
      'is_deleted': deleted ? 1 : 0,
      'hidden_effective': hiddenEffective ? 1 : 0,
    });
  }

  Future<void> file(String id, String? folderId,
      {bool binned = false, bool hidden = false}) async {
    await db.insert('files', {
      'id': id,
      'account_id': _acct,
      'filename': '$id.jpg',
      'size_bytes': 1,
      'created_at': 1700000000000,
      'is_uploaded': 1,
      'is_deleted': binned ? 1 : 0,
      'is_hidden': hidden ? 1 : 0,
      'folder_id': folderId,
      'type': CnestFileType.image.index,
    });
  }

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await DatabaseService.createSchemaForTest(db);
    await DatabaseService.createSyncSchemaForTest(db);
    DatabaseService().debugSetDatabase(db);
    DatabaseService().setCurrentAccount(_acct);

    // Phone Backup / A55 / {Camera, Screenshots} + Phone Backup / V / Camera.
    await folder(rootId, 'Phone Backup');
    await folder(devA, 'Samsung SM-A556E', parent: rootId);
    await folder(devB, 'Vivo V2158', parent: rootId);
    await folder(camA, 'Camera', parent: devA);
    await folder(camB, 'Camera', parent: devB);
    await folder(shotsA, 'Screenshots', parent: devA);

    await file('a1', camA);
    await file('a2', camA);
    await file('b1', camB);
    await file('s1', shotsA);
    await file('binned', camA, binned: true);
    await file('hidden', camB, hidden: true);
    await file('loose', null);
  });

  tearDown(() async {
    await DatabaseService().closeDatabase();
  });

  test('same-named albums on two devices merge into ONE derived album '
      'whose contents are the union', () async {
    final albums = await DatabaseService().getDeviceAlbums();
    expect(albums.map((a) => a.name).toList(), ['Camera', 'Screenshots']);

    final camera = albums.first;
    expect(camera.isSmart, isTrue);
    // Union of both Camera folders, minus binned + hidden files.
    expect(camera.fileCount, 3);

    final files = await DatabaseService().getFilesForAlbum(camera);
    expect(files.map((f) => f.id).toSet(), {'a1', 'a2', 'b1'});
  });

  test('binned and hidden files are excluded; user folders and loose files '
      'never appear', () async {
    final albums = await DatabaseService().getDeviceAlbums();
    final shots = albums.last;
    expect(shots.name, 'Screenshots');
    final files = await DatabaseService().getFilesForAlbum(shots);
    expect(files.map((f) => f.id).toList(), ['s1']);
  });

  test('a hidden album folder removes its derived album (or its share of '
      'the union)', () async {
    await db.update('folders', {'hidden_effective': 1},
        where: 'id = ?', whereArgs: [camA]);
    final albums = await DatabaseService().getDeviceAlbums();
    final camera = albums.firstWhere((a) => a.name == 'Camera');
    final files = await DatabaseService().getFilesForAlbum(camera);
    expect(files.map((f) => f.id).toList(), ['b1'],
        reason: 'A55 Camera hidden -> only the V share remains');
  });

  test('a binned album folder drops out of the union', () async {
    await db.update('folders', {'is_deleted': 1},
        where: 'id = ?', whereArgs: [camB]);
    final albums = await DatabaseService().getDeviceAlbums();
    final camera = albums.firstWhere((a) => a.name == 'Camera');
    final files = await DatabaseService().getFilesForAlbum(camera);
    expect(files.map((f) => f.id).toSet(), {'a1', 'a2'});
  });

  test('another account\'s tree never bleeds in', () async {
    final otherRoot = SystemFolders.rootId(_other);
    final otherDev = SystemFolders.deviceId(_other, keyA);
    final otherCam = SystemFolders.albumId(_other, keyA, 'Downloads');
    await folder(otherRoot, 'Phone Backup', account: _other);
    await folder(otherDev, 'Samsung SM-A556E',
        parent: otherRoot, account: _other);
    await folder(otherCam, 'Downloads', parent: otherDev, account: _other);

    final albums = await DatabaseService().getDeviceAlbums();
    expect(albums.map((a) => a.name).toList(), ['Camera', 'Screenshots']);
  });
}
