/// The Free-limit and upload-failure plumbing that the Phase 2 walkthrough
/// (20 Oct 2026) found broken: the typed limit error fell into the generic
/// "Code: UPLOAD" mapper, batch summaries had no word for "over the limit",
/// and transient Drive failures were never retried.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/cnest_errors.dart';
import 'package:ciphernest/services/upload_pipeline.dart';
import 'package:ciphernest/services/upload_retry.dart';

void main() {
  group('mapUploadError', () {
    test('a typed error passes through untouched', () {
      const e = FreeLimitReachedError(binned: 2, notStored: 3);
      expect(identical(UploadPipeline.mapUploadError(e), e), isTrue);
      expect(UploadPipeline.mapUploadError(const StorageFullError()),
          isA<StorageFullError>());
    });

    test('an unknown raw exception still maps to the UPLOAD code', () {
      final mapped = UploadPipeline.mapUploadError(Exception('boom'));
      expect(mapped, isA<UnexpectedError>());
      expect((mapped as UnexpectedError).code, 'UPLOAD');
    });
  });

  group('FreeLimitReachedError message', () {
    test('plain', () {
      const e = FreeLimitReachedError();
      expect(e.message, contains('at the limit'));
      expect(e.message, isNot(contains('Recycle Bin')));
      expect(e.message, isNot(contains('were not uploaded')));
    });

    test('says how many did not fit and where the slots went', () {
      const e = FreeLimitReachedError(binned: 4, notStored: 7);
      expect(e.message, contains('7 files were not uploaded'));
      expect(e.message, contains('4 of them are in the Recycle Bin'));
    });

    test('singular bin wording', () {
      const e = FreeLimitReachedError(binned: 1);
      expect(e.message, contains('One of them is in the Recycle Bin'));
    });
  });

  group('summarizeOutcomes', () {
    test('counts over-limit files apart from real failures', () {
      const limit = FreeLimitReachedError(notStored: 2);
      final s = UploadPipeline.summarizeOutcomes(const [
        UploadOutcome.forTest('a', ok: true),
        UploadOutcome.forTest('b', ok: true, skippedDuplicate: true),
        UploadOutcome.forTest('c', ok: false, error: limit),
        UploadOutcome.forTest('d', ok: false, error: limit),
        UploadOutcome.forTest('e', ok: false, error: 'socket'),
      ]);
      expect(s, '1 file secured · 1 already in your vault · '
          '2 over the Free limit · 1 failed');
    });
  });

  group('isTransientCloudError', () {
    test('rate limit, 5xx and died-mid-transfer retry', () {
      expect(
          isTransientCloudError(Exception(
              'DetailedApiRequestError(status: 403, message: User rate limit exceeded.)')),
          isTrue);
      expect(isTransientCloudError(Exception('status: 429')), isTrue);
      expect(isTransientCloudError(Exception('status: 503 backendError')),
          isTrue);
      expect(isTransientCloudError(Exception('SocketException: reset')),
          isTrue);
    });

    test('quota, auth and offline do not', () {
      expect(
          isTransientCloudError(Exception(
              'status: 403, message: storageQuotaExceeded')),
          isFalse);
      expect(isTransientCloudError(Exception('401 invalid_grant')), isFalse);
      expect(isTransientCloudError(Exception('Failed host lookup')), isFalse);
      expect(isTransientCloudError(Exception('something else')), isFalse);
    });
  });

  group('retryTransientUpload', () {
    Future<void> noSleep(Duration _) async {}

    test('retries a transient failure and returns the eventual value',
        () async {
      var calls = 0;
      final v = await retryTransientUpload(() async {
        calls++;
        if (calls < 3) throw Exception('status: 429');
        return 'id';
      }, sleep: noSleep);
      expect(v, 'id');
      expect(calls, 3);
    });

    test('gives up after maxAttempts', () async {
      var calls = 0;
      await expectLater(
        retryTransientUpload(() async {
          calls++;
          throw Exception('status: 503');
        }, maxAttempts: 4, sleep: noSleep),
        throwsException,
      );
      expect(calls, 4);
    });

    test('a non-transient failure is not retried', () async {
      var calls = 0;
      await expectLater(
        retryTransientUpload(() async {
          calls++;
          throw Exception('storageQuotaExceeded');
        }, sleep: noSleep),
        throwsException,
      );
      expect(calls, 1);
    });

    test('backoff doubles', () async {
      final waits = <Duration>[];
      var calls = 0;
      await retryTransientUpload(() async {
        calls++;
        if (calls < 4) throw Exception('status: 500');
        return 1;
      }, sleep: (d) async => waits.add(d));
      expect(waits, hasLength(3));
      expect(waits[0].inMilliseconds, inInclusiveRange(1000, 1500));
      expect(waits[1].inMilliseconds, inInclusiveRange(2000, 2500));
      expect(waits[2].inMilliseconds, inInclusiveRange(4000, 4500));
    });
  });
}
