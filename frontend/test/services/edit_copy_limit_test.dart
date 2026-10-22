/// An edited copy and a captured video frame are new vault rows, so they
/// answer to the Free cap like any upload. Found on device 22 Oct 2026: a
/// vault at 1,000 files could still "Save as copy" from the editor.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/cnest_errors.dart';
import 'package:ciphernest/services/database_service.dart';
import 'package:ciphernest/services/image_edit_service.dart';
import 'package:ciphernest/services/subscription_service.dart';
import 'package:ciphernest/src/models/file_model.dart';

const _acct = 'google_test@example.com';

Map<String, Object?> _row(String id) => {
      'id': id,
      'cloud_id': 'c-$id',
      'account_id': _acct,
      'filename': '$id.jpg',
      'size_bytes': 10,
      'created_at': 1000,
      'is_uploaded': 1,
      'is_deleted': 0,
      'type': 0,
      'prior_key': 0,
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

  Future<void> fill(int n) async {
    final b = db.batch();
    for (var i = 0; i < n; i++) {
      b.insert('files', _row('live-$i'));
    }
    await b.commit(noResult: true);
  }

  final source = CnestFile(
    id: 'live-0',
    cloudId: 'c-live-0',
    accountId: _acct,
    filename: 'live-0.jpg',
    sizeBytes: 10,
    createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
    type: CnestFileType.image,
    isUploaded: true,
  );
  final bytes = Uint8List.fromList(List.filled(64, 1));

  test('save as copy at the cap throws the typed limit error', () async {
    await fill(FreeTierGuard.freeFileLimit);
    await expectLater(
      ImageEditService().saveEdit(
        source: source,
        editedBytes: bytes,
        replaceOriginal: false,
      ),
      throwsA(isA<FreeLimitReachedError>()),
    );
    // Nothing was added: the guard runs before the row insert.
    expect(await DatabaseService().countStoredFiles(),
        FreeTierGuard.freeFileLimit);
  });

  test('replace original at the cap is not gated', () async {
    await fill(FreeTierGuard.freeFileLimit);
    // The path proceeds past the guard into image compression, which has no
    // platform channel under test. Any error but the limit one is the proof.
    await expectLater(
      ImageEditService().saveEdit(
        source: source,
        editedBytes: bytes,
        replaceOriginal: true,
      ),
      throwsA(isNot(isA<FreeLimitReachedError>())),
    );
  });

  test('save as copy one under the cap is not gated', () async {
    await fill(FreeTierGuard.freeFileLimit - 1);
    await expectLater(
      ImageEditService().saveEdit(
        source: source,
        editedBytes: bytes,
        replaceOriginal: false,
      ),
      throwsA(isNot(isA<FreeLimitReachedError>())),
    );
  });
}
