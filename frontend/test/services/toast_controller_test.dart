/// Replace-not-queue policy + per-severity durations for the toast pill.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/notify.dart';

void main() {
  final toasts = ToastController();

  setUp(toasts.debugReset);

  test('info shows for 2.5s then clears itself', () {
    fakeAsync((async) {
      Notify.info('Saved');
      expect(toasts.current?.message, 'Saved');
      expect(toasts.current?.isError, isFalse);
      async.elapse(const Duration(milliseconds: 2499));
      expect(toasts.current, isNotNull);
      async.elapse(const Duration(milliseconds: 1));
      expect(toasts.current, isNull);
    });
  });

  test('errors get the longer 4s duration and the error flag', () {
    fakeAsync((async) {
      Notify.error('Could not save');
      expect(toasts.current?.isError, isTrue);
      async.elapse(const Duration(milliseconds: 3999));
      expect(toasts.current, isNotNull);
      async.elapse(const Duration(milliseconds: 1));
      expect(toasts.current, isNull);
    });
  });

  test('REPLACE policy: a new toast displaces the old one and restarts the '
      'clock; seq increments for AnimatedSwitcher keys', () {
    fakeAsync((async) {
      Notify.info('first');
      final firstSeq = toasts.current!.seq;
      async.elapse(const Duration(milliseconds: 2000));
      Notify.info('second');
      expect(toasts.current!.message, 'second');
      expect(toasts.current!.seq, firstSeq + 1);
      // The first toast's timer must NOT clear the second at its old
      // deadline (2.5s from the first show).
      async.elapse(const Duration(milliseconds: 600));
      expect(toasts.current?.message, 'second');
      async.elapse(const Duration(milliseconds: 1900));
      expect(toasts.current, isNull);
    });
  });

  test('dismiss (swipe) clears instantly', () {
    fakeAsync((async) {
      Notify.info('bye');
      toasts.dismiss();
      expect(toasts.current, isNull);
    });
  });
}
