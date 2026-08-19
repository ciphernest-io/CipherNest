/// C11 guard: album membership ops are only recorded for files with a
/// createFile op in the log — the materializer's FK guard silently drops
/// pairs for op-less files, so the choke point must refuse them instead of
/// reporting success for an add that can never materialize.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/database_service.dart';

const _acct = 'g_test@example.com';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await DatabaseService.createSchemaForTest(db);
    await DatabaseService.createSyncSchemaForTest(db);
    DatabaseService().debugSetDatabase(db);
    DatabaseService().setCurrentAccount(_acct);

    Future<void> op(String kind, String target, int seq) => db.insert(
        'sync_ops', {
          'account_id': _acct,
          'device_id': 'devA',
          'seq': seq,
          'hlc_wall': seq,
          'hlc_counter': 0,
          'kind': kind,
          'target_id': target,
          'pending': 0,
        }).then((_) {});

    await op('createFile', 'backed', 0);
    await op('renameFile', 'renamed-only', 1); // edit op is NOT a create
    await op('createFile', 'foreign', 2); // wrong account below
    await db.update('sync_ops', {'account_id': 'other@example.com'},
        where: "target_id = 'foreign'");
  });

  tearDown(() async {
    await DatabaseService().closeDatabase();
  });

  test('only files with a createFile op in THIS account pass the filter, '
      'order-preserving', () async {
    final backed = await DatabaseService().opBackedFileIds(
        ['opless', 'backed', 'renamed-only', 'foreign']);
    expect(backed, ['backed'],
        reason: 'op-less, edit-only, and foreign-account files must be '
            'refused — their membership ops can never materialize');
  });

  test('empty input and signed-out are safe no-ops', () async {
    expect(await DatabaseService().opBackedFileIds([]), isEmpty);
  });
}
