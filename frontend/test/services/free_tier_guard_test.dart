/// What counts toward the Free cap, and the guard's answers around it.
///
/// The walkthrough bypass: bin a file, upload a new one, restore the binned
/// one, 1,001 files. Binned rows hold a slot now. Pending rows hold a slot.
/// Prior-key rows (foreign blobs this vault cannot open) do not.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/database_service.dart';
import 'package:ciphernest/services/subscription_service.dart';

const _acct = 'google_test@example.com';

Map<String, Object?> _row(String id,
        {int deleted = 0, int uploaded = 1, int priorKey = 0}) =>
    {
      'id': id,
      'cloud_id': uploaded == 1 ? 'c-$id' : null,
      'account_id': _acct,
      'filename': '$id.jpg',
      'size_bytes': 10,
      'created_at': 1000,
      'is_uploaded': uploaded,
      'is_deleted': deleted,
      'type': 0,
      'prior_key': priorKey,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() => databaseFactory = databaseFactoryFfi);

  late Database db;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SubscriptionService().resetForTest();
    FreeTierGuard.resetThrottleForTest();
    db = await databaseFactory.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    await DatabaseService.createSchemaForTest(db);
    await DatabaseService.createSyncSchemaForTest(db);
    DatabaseService().debugSetDatabase(db);
    DatabaseService().setCurrentAccount(_acct);
  });
  tearDown(() async => DatabaseService().closeDatabase());

  Future<void> fill(int n, {int binned = 0, int pending = 0, int prior = 0}) async {
    final b = db.batch();
    var k = 0;
    for (var i = 0; i < n; i++) {
      b.insert('files', _row('live-${k++}'));
    }
    for (var i = 0; i < binned; i++) {
      b.insert('files', _row('bin-${k++}', deleted: 1));
    }
    for (var i = 0; i < pending; i++) {
      b.insert('files', _row('pend-${k++}', uploaded: 0));
    }
    for (var i = 0; i < prior; i++) {
      b.insert('files', _row('prior-${k++}', priorKey: 1));
    }
    await b.commit(noResult: true);
  }

  test('binned and pending rows count; prior-key rows do not', () async {
    await fill(5, binned: 2, pending: 1, prior: 3);
    expect(await DatabaseService().countStoredFiles(), 8);
    expect(await DatabaseService().countBinnedFiles(), 2);
  });

  test('status at 999 live + 1 binned is at the limit', () async {
    await fill(999, binned: 1);
    final st = await FreeTierGuard.status();
    expect(st.isPlus, isFalse);
    expect(st.stored, 1000);
    expect(st.binned, 1);
    expect(st.atLimit, isTrue);
    expect(st.remaining, 0);
    expect(await FreeTierGuard.canStoreMore(), isFalse);
  });

  test('purging the binned row frees the slot', () async {
    await fill(999, binned: 1);
    await db.delete('files', where: 'is_deleted = 1');
    expect(await FreeTierGuard.canStoreMore(), isTrue);
    expect((await FreeTierGuard.status()).remaining, 1);
  });

  test('near-limit threshold is 90%', () async {
    await fill(899);
    expect((await FreeTierGuard.status()).nearLimit, isFalse);
    await db.insert('files', _row('one-more'));
    expect((await FreeTierGuard.status()).nearLimit, isTrue);
  });

  test('a batch that does not fit is refused as a whole, a fitting one passes',
      () async {
    await fill(998);
    expect(await FreeTierGuard.canStoreMore(adding: 2), isTrue);
    expect(await FreeTierGuard.canStoreMore(adding: 3), isFalse);
  });

  test('the limit error carries the bin count', () async {
    await fill(997, binned: 3);
    final e = await FreeTierGuard.limitError(notStored: 2);
    expect(e.binned, 3);
    expect(e.notStored, 2);
  });

  test('Plus is never gated', () async {
    SharedPreferences.setMockInitialValues({'plus_is_lifetime_v1': true});
    SubscriptionService().resetForTest();
    await fill(1200);
    expect(await FreeTierGuard.canStoreMore(adding: 50), isTrue);
    final st = await FreeTierGuard.status();
    expect(st.isPlus, isTrue);
    expect(st.atLimit, isFalse);
    expect(st.nearLimit, isFalse);
  });

  test('fmtCount groups thousands', () {
    expect(FreeTierGuard.fmtCount(0), '0');
    expect(FreeTierGuard.fmtCount(999), '999');
    expect(FreeTierGuard.fmtCount(1000), '1,000');
    expect(FreeTierGuard.fmtCount(1234567), '1,234,567');
  });
}
