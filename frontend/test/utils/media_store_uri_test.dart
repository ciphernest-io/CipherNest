/// extractMediaStoreId: both content-URI families Android pickers return.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/src/utils/media_store_uri.dart';

void main() {
  test('direct MediaStore URIs yield the trailing id', () {
    expect(
      extractMediaStoreId('content://media/external/images/media/123'),
      '123',
    );
    expect(
      extractMediaStoreId('content://media/external/video/media/9987'),
      '9987',
    );
  });

  test('direct URI with query string still yields digits', () {
    expect(
      extractMediaStoreId('content://media/external/images/media/55?x=1'),
      '55',
    );
  });

  test('SAF media-documents URIs decode type:id', () {
    expect(
      extractMediaStoreId(
          'content://com.android.providers.media.documents/document/video%3A123'),
      '123',
    );
    expect(
      extractMediaStoreId(
          'content://com.android.providers.media.documents/document/image%3A42'),
      '42',
    );
    expect(
      extractMediaStoreId(
          'content://com.android.providers.media.documents/document/audio%3A7'),
      '7',
    );
    // Downloads provider serves MediaStore ids with the msf prefix.
    expect(
      extractMediaStoreId(
          'content://com.android.providers.media.documents/document/msf%3A314'),
      '314',
    );
  });

  test('pre-decoded document id also parses', () {
    expect(
      extractMediaStoreId(
          'content://com.android.providers.media.documents/document/video:123'),
      '123',
    );
  });

  test('externalstorage document URIs are NOT MediaStore ids', () {
    expect(
      extractMediaStoreId(
          'content://com.android.externalstorage.documents/document/primary%3ADCIM%2Fv.mp4'),
      isNull,
    );
  });

  test('unknown kinds and non-numeric ids are rejected', () {
    expect(
      extractMediaStoreId(
          'content://com.android.providers.media.documents/document/document%3A9'),
      isNull,
    );
    expect(
      extractMediaStoreId(
          'content://com.android.providers.media.documents/document/video%3Aabc'),
      isNull,
    );
    expect(
      extractMediaStoreId(
          'content://com.android.providers.media.documents/document/video%3A'),
      isNull,
    );
  });

  test('garbage returns null', () {
    expect(extractMediaStoreId('file:///storage/emulated/0/x.mp4'), isNull);
    expect(extractMediaStoreId('not a uri'), isNull);
    expect(extractMediaStoreId(''), isNull);
  });
}
