import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/thumb_store.dart';

void main() {
  setUp(() => ThumbStore.instance.clear());
  tearDownAll(() => ThumbStore.instance.clear());

  test('byte identity is preserved and providers are stable instances', () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    ThumbStore.instance.putBytes('a', bytes);
    // The SAME instance must come back — MemoryImage equality (and with it
    // the shared ImageCache entry) is byte-list identity.
    expect(identical(ThumbStore.instance.peek('a')!.bytes, bytes), isTrue);
    final p1 = ThumbStore.instance.providerFor('a', width: 300);
    final p2 = ThumbStore.instance.providerFor('a', width: 300);
    expect(p1, isNotNull);
    expect(identical(p1, p2), isTrue);
    expect(p1, isA<ResizeImage>());
    // Distinct widths are distinct providers (different decode tiers).
    final dense = ThumbStore.instance.providerFor('a', width: 120);
    expect(identical(p1, dense), isFalse);
  });

  test('replacing bytes invalidates cached providers', () {
    ThumbStore.instance.putBytes('c', Uint8List.fromList([1]));
    final p1 = ThumbStore.instance.providerFor('c', width: 300);
    ThumbStore.instance.putBytes('c', Uint8List.fromList([2]));
    final p2 = ThumbStore.instance.providerFor('c', width: 300);
    expect(identical(p1, p2), isFalse);
  });

  test('diskPath does not displace bytes; bytes-less entries use paths', () {
    final bytes = Uint8List.fromList([7]);
    ThumbStore.instance.putBytes('d', bytes);
    ThumbStore.instance.putDiskPath('d', '/tmp/x.jpg');
    final p = ThumbStore.instance.providerFor('d', width: 300)! as ResizeImage;
    expect(p.imageProvider, isA<MemoryImage>());

    ThumbStore.instance.putDiskPath('e', '/tmp/y.jpg');
    final pe = ThumbStore.instance.providerFor('e', width: 300)! as ResizeImage;
    expect(pe.imageProvider, isA<FileImage>());
  });

  test('evict and clear drop entries', () {
    ThumbStore.instance.putBytes('f', Uint8List.fromList([1]));
    ThumbStore.instance.evict('f');
    expect(ThumbStore.instance.peek('f'), isNull);
    ThumbStore.instance.putBytes('g', Uint8List.fromList([1]));
    ThumbStore.instance.clear();
    expect(ThumbStore.instance.peek('g'), isNull);
  });

  test('entry cap evicts oldest-first', () {
    for (var i = 0; i < 1205; i++) {
      ThumbStore.instance.putBytes('id$i', Uint8List.fromList([i & 0xff]));
    }
    expect(ThumbStore.instance.peek('id0'), isNull);
    expect(ThumbStore.instance.peek('id1204'), isNotNull);
  });

  test('byte cap drops old bytes but keeps path-backed entries', () {
    // 70 x 1 MiB > the 64 MiB byte cap.
    ThumbStore.instance.putDiskPath('keeper', '/tmp/k.jpg');
    for (var i = 0; i < 70; i++) {
      ThumbStore.instance.putBytes('big$i', Uint8List(1 << 20));
    }
    expect(ThumbStore.instance.peek('keeper'), isNotNull);
    expect(ThumbStore.instance.peek('big69')!.bytes, isNotNull);
    expect(ThumbStore.instance.peek('big0')?.bytes, isNull);
  });
}
